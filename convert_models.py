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

MODELS = [
    # (имя в приложении, адрес весов, число сверточных слоёв)
    ("NeuralGeneral",
     "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth", 32),
    ("NeuralLight",
     "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth", 16),
]


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


def convert(name, url, num_conv):
    print(f"=== {name}: скачиваю веса ===", flush=True)
    pth = f"weights_{name}.pth"
    urllib.request.urlretrieve(url, pth)

    state = torch.load(pth, map_location="cpu")
    key = "params_ema" if "params_ema" in state else "params"
    net = SRVGGNetCompact(num_conv=num_conv)
    net.load_state_dict(state[key], strict=True)
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
    os.remove(pth)


def main():
    ok = []
    for name, url, num_conv in MODELS:
        try:
            convert(name, url, num_conv)
            ok.append(name)
            print(f"::notice::Нейро-модель {name} собрана")
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            message = str(e).replace("\n", " ")[:300]
            print(f"::warning::Нейро-модель {name} не собралась: {message}")
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
