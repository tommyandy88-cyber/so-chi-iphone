"""Warm the MIT-licensed Vietnamese streaming Moonshine model at build time.
The old Vosk small model is deliberately not used for new recognition.
"""
from pathlib import Path
import os

BASE=Path(__file__).resolve().parent
os.environ.setdefault("MOONSHINE_VOICE_CACHE",str(BASE/"models"))
from moonshine_voice import get_model_for_language

def main():
    path,arch=get_model_for_language("vi")
    target=Path(path)
    if not target.is_dir() or not list(target.glob("*.ort")):
        raise RuntimeError("Missing Vietnamese Moonshine streaming model artifacts")
    print("Moonshine Vietnamese model downloaded:",target,"architecture:",arch,flush=True)

if __name__=="__main__":
    main()
