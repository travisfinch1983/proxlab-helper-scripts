#!/usr/bin/env python3
"""
Native Weaviate multi2vec-clip inference service.
Drop-in replacement for cr.weaviate.io/semitechnologies/multi2vec-clip.

API: POST /vectorize {texts[], images[]} → {textVectors[], imageVectors[]}
     GET /.well-known/live → 204
     GET /.well-known/ready → 204
     GET /meta → model info

Supports SentenceTransformers CLIP models (default) and OpenCLIP models.

NOTE: This service is created by ProxLab Helper Scripts and is NOT made by
or associated with Weaviate or SeMI Technologies.
"""

import os
import io
import base64
import logging
from contextlib import asynccontextmanager

import torch
import uvicorn
from fastapi import FastAPI, Response
from pydantic import BaseModel, Field
from PIL import Image
from sentence_transformers import SentenceTransformer

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("multi2vec-clip")

MODEL_NAME = os.environ.get("MODEL_NAME", "clip-ViT-B-32")
MODEL_PATH = os.environ.get("MODEL_PATH", "./models/model")
PORT = int(os.environ.get("PORT", "8080"))
ENABLE_CUDA = os.environ.get("ENABLE_CUDA", "0") == "1"

model: SentenceTransformer = None


class VectorizeRequest(BaseModel):
    texts: list[str] = Field(default_factory=list)
    images: list[str] = Field(default_factory=list)  # base64-encoded


class VectorizeResponse(BaseModel):
    textVectors: list[list[float]] = Field(default_factory=list)
    imageVectors: list[list[float]] = Field(default_factory=list)


def decode_image(b64_data: str) -> Image.Image:
    """Decode base64 image data to PIL Image (RGB)."""
    img_bytes = base64.b64decode(b64_data)
    img = Image.open(io.BytesIO(img_bytes))
    return img.convert("RGB")


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    device = "cuda" if ENABLE_CUDA and torch.cuda.is_available() else "cpu"
    log.info(f"Loading CLIP model: {MODEL_NAME} on {device}")

    if os.path.isdir(MODEL_PATH):
        model = SentenceTransformer(MODEL_PATH, device=device)
        log.info(f"Loaded model from cache: {MODEL_PATH}")
    else:
        model = SentenceTransformer(MODEL_NAME, device=device)
        os.makedirs(os.path.dirname(MODEL_PATH), exist_ok=True)
        model.save(MODEL_PATH)
        log.info(f"Downloaded and cached model to {MODEL_PATH}")

    dim = model.get_sentence_embedding_dimension()
    log.info(f"CLIP model ready — dim={dim}")
    yield
    log.info("Shutting down")


app = FastAPI(lifespan=lifespan)


@app.get("/.well-known/live", status_code=204)
async def live():
    return Response(status_code=204)


@app.get("/.well-known/ready", status_code=204)
async def ready():
    if model is None:
        return Response(status_code=503)
    return Response(status_code=204)


@app.get("/meta")
async def meta():
    return {
        "model": MODEL_NAME,
        "dim": model.get_sentence_embedding_dimension() if model else 0,
        "type": "clip",
    }


@app.post("/vectorize", response_model=VectorizeResponse)
async def vectorize(req: VectorizeRequest):
    try:
        text_vectors = []
        image_vectors = []

        if req.texts:
            embeddings = model.encode(req.texts, normalize_embeddings=True)
            text_vectors = [e.tolist() for e in embeddings]

        if req.images:
            images = [decode_image(img_b64) for img_b64 in req.images]
            embeddings = model.encode(images, normalize_embeddings=True)
            image_vectors = [e.tolist() for e in embeddings]

        return VectorizeResponse(textVectors=text_vectors, imageVectors=image_vectors)
    except Exception as e:
        log.error(f"Vectorization error: {e}")
        return Response(content=f'{{"error": "{e}"}}', status_code=500, media_type="application/json")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
