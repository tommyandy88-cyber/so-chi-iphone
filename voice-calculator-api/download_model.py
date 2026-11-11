"""Fetch the official Apache 2.0 Vietnamese Vosk model during Render build.
Nothing is stored in GitHub; the archive is removed after extraction.
"""
from pathlib import Path
import os, shutil, tempfile, urllib.request, zipfile

BASE=Path(__file__).resolve().parent
TARGET=BASE/"model"/"vosk-model-small-vn-0.4"
SOURCES=[
  "https://alphacephei.com/vosk/models/vosk-model-small-vn-0.4.zip",
  "https://huggingface.co/rhasspy/vosk-models/resolve/main/vi/vosk-model-small-vn-0.4.zip",
]
def main():
    if (TARGET/"am"/"final.mdl").exists():
        print("Vietnamese speech model already installed")
        return
    TARGET.parent.mkdir(parents=True,exist_ok=True)
    failures=[]
    for url in SOURCES:
        try:
            print("Downloading Vietnamese speech model from",url,flush=True)
            with tempfile.TemporaryDirectory() as temp:
                archive=Path(temp)/"model.zip"
                request=urllib.request.Request(url,headers={"User-Agent":"KanaanVoiceCalculator/1.0"})
                with urllib.request.urlopen(request,timeout=120) as res,open(archive,"wb") as out:
                    shutil.copyfileobj(res,out)
                if archive.stat().st_size>110_000_000: raise ValueError("model archive too large")
                with zipfile.ZipFile(archive) as z:
                    members=z.infolist()
                    if sum(item.file_size for item in members)>260_000_000: raise ValueError("extracted model too large")
                    for member in members:
                        p=Path(member.filename)
                        if not p.parts or p.parts[0]!="vosk-model-small-vn-0.4" or any(x in ("..","") for x in p.parts):
                            raise ValueError("unsafe model archive")
                    z.extractall(TARGET.parent)
            if not (TARGET/"am"/"final.mdl").exists(): raise FileNotFoundError("missing Vosk model files")
            print("Model installed successfully",flush=True)
            return
        except Exception as exc:
            failures.append(f"{type(exc).__name__}: {str(exc)[:250]}")
            shutil.rmtree(TARGET,ignore_errors=True)
    raise RuntimeError("Unable to download Vietnamese model: "+" / ".join(failures))
if __name__=="__main__":main()
