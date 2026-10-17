"""
Скачивает веса Real-ESRGAN и превращает их в модели Core ML для iPhone.
Запускается на GitHub перед сборкой приложения. Если что-то не получилось,
приложение всё равно соберётся, просто без нейро-улучшения.
"""
import os
import shutil
import subprocess
import sys
import traceback
import urllib.request

import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct

TILE = 256

BASE = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/"
GENERAL = BASE + "realesr-general-x4v3.pth"
GENERAL_WDN = BASE + "realesr-general-wdn-x4v3.pth"   # версия с сильным шумоподавлением
ANIME = BASE + "realesr-animevideov3.pth"

MODELS = [
    # (имя в приложении, [(адрес весов, доля)], число сверточных слоёв)
    ("NeuralGeneral", [(GENERAL, 1.0)], 32),
    ("NeuralLight", [(ANIME, 1.0)], 16),
    # смесь весов: больше шумоподавления, поэтому однотонные текстуры сглаживаются сильнее
    ("NeuralSmooth", [(GENERAL_WDN, 0.85), (GENERAL, 0.15)], 32),
]

_weights_cache = {}


class SRVGGNetCompact(nn.Module):
    """Архитектура Real-ESRGAN compact (копия из репозитория xinntao/Real-ESRGAN)."""

    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=16, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        base = F.interpolate(x, scale_factor=self.upscale, mode="nearest")
        return out + base


class Wrapper(nn.Module):
    """Вход 0..1 (масштабирование делает Core ML), выход 0..255 для картинки."""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        return torch.clamp(self.net(x), 0.0, 1.0) * 255.0


def load_weights(url):
    if url not in _weights_cache:
        print(f"=== скачиваю {os.path.basename(url)} ===", flush=True)
        path = "weights_" + os.path.basename(url)
        urllib.request.urlretrieve(url, path)
        state = torch.load(path, map_location="cpu")
        key = "params_ema" if "params_ema" in state else "params"
        _weights_cache[url] = state[key]
        os.remove(path)
    return _weights_cache[url]


def blend_weights(sources):
    """Смешивает веса нескольких сетей (так в Real-ESRGAN регулируют силу шумоподавления)."""
    if len(sources) == 1:
        return load_weights(sources[0][0])
    total = sum(weight for _, weight in sources)
    states = [(load_weights(url), weight / total) for url, weight in sources]
    result = {}
    for key in states[0][0]:
        result[key] = sum(state[key].float() * weight for state, weight in states)
    return result


def convert(name, sources, num_conv):
    weights = blend_weights(sources)
    net = SRVGGNetCompact(num_conv=num_conv)
    net.load_state_dict(weights, strict=True)
    net.eval()

    wrapped = Wrapper(net).eval()
    example = torch.rand(1, 3, TILE, TILE)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    print(f"=== {name}: конвертирую в Core ML ===", flush=True)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="input", shape=(1, 3, TILE, TILE),
                             scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )

    os.makedirs("Models", exist_ok=True)
    package = f"Models/{name}.mlpackage"
    if os.path.exists(package):
        shutil.rmtree(package)
    mlmodel.save(package)

    print(f"=== {name}: компилирую ===", flush=True)
    subprocess.run(["xcrun", "coremlcompiler", "compile", package, "Models"], check=True)
    shutil.rmtree(package)


def add_models_to_project():
    """Подключает папку Models к проекту, только если модели действительно собрались."""
    path = "project.yml"
    text = open(path, encoding="utf-8").read()
    if "path: Models" in text:
        return
    marker = '        includes:\n          - "*.swift"\n'
    if marker not in text:
        print("::warning::project.yml: не найдено место для папки Models")
        return
    text = text.replace(marker, marker + "      - path: Models\n        type: folder\n", 1)
    open(path, "w", encoding="utf-8").write(text)


def main():
    ok = []
    for name, sources, num_conv in MODELS:
        try:
            convert(name, sources, num_conv)
            ok.append(name)
            print(f"::notice::Нейро-модель {name} собрана")
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            message = str(e).replace("\n", " ")[:300]
            print(f"::warning::Нейро-модель {name} не собралась: {message}")
    if not ok:
        sys.exit(1)
    add_models_to_project()


if __name__ == "__main__":
    main()
