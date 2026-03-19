#!/usr/bin/env python3
"""
Native Weaviate multi2vec-clip inference service.
Drop-in replacement for cr.weaviate.io/semitechnologies/multi2vec-clip.

API: POST /vectorize {texts[], images[]} → {textVectors[], imageVectors[]}
     GET /.well-known/live → 204
     GET /.well-known/ready → 204
     GET /meta → model info

NOTE: This service is created by ProxLab Helper Scripts and is NOT made by
or associated with Weaviate or SeMI Technologies.
"""

import os
import io
import json
import base64
import logging
from contextlib import asynccontextmanager

import torch
import uvicorn
from fastapi import FastAPI, Response, Request
from PIL import Image

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("multi2vec-clip")

MODEL_NAME = os.environ.get("MODEL_NAME", "clip-ViT-B-32")
MODEL_PATH = os.environ.get("MODEL_PATH", "./models/model")
PORT = int(os.environ.get("PORT", "8080"))
ENABLE_CUDA = os.environ.get("ENABLE_CUDA", "0") == "1"

model = None


def decode_image(b64_data: str) -> Image.Image:
    img_bytes = base64.b64decode(b64_data)
    return Image.open(io.BytesIO(img_bytes)).convert("RGB")


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    from sentence_transformers import SentenceTransformer

    device = "cuda" if ENABLE_CUDA and torch.cuda.is_available() else "cpu"
    log.info(f"Loading CLIP model: {MODEL_NAME} on {device}")
    model = SentenceTransformer(MODEL_PATH if os.path.isdir(MODEL_PATH) else MODEL_NAME, device=device)
    if not os.path.isdir(MODEL_PATH):
        os.makedirs(os.path.dirname(MODEL_PATH), exist_ok=True)
        model.save(MODEL_PATH)
    log.info(f"CLIP model ready — dim={model.get_sentence_embedding_dimension()}")
    yield
    log.info("Shutting down")


app = FastAPI(lifespan=lifespan)


@app.get("/.well-known/live", status_code=204)
@app.get("/.well-known/ready", status_code=204)
async def health():
    return Response(status_code=204 if model else 503)


@app.get("/meta")
async def meta():
    return {
        "model": MODEL_NAME,
        "dim": model.get_sentence_embedding_dimension() if model else 0,
        "type": "clip",
    }


@app.post("/vectorize")
async def vectorize(request: Request):
    try:
        body = await request.json()
        texts = body.get("texts", [])
        images = body.get("images", [])
        text_vectors = []
        image_vectors = []

        if texts:
            embeddings = model.encode(texts, normalize_embeddings=True)
            text_vectors = [e.tolist() for e in embeddings]

        if images:
            pil_images = [decode_image(img_b64) for img_b64 in images]
            embeddings = model.encode(pil_images, normalize_embeddings=True)
            image_vectors = [e.tolist() for e in embeddings]

        return {"textVectors": text_vectors, "imageVectors": image_vectors}
    except Exception as e:
        log.error(f"Vectorization error: {e}")
        return Response(content=json.dumps({"error": str(e)}), status_code=500, media_type="application/json")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
