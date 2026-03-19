#!/usr/bin/env python3
"""
Native Weaviate text2vec-transformers inference service.
Drop-in replacement for cr.weaviate.io/semitechnologies/transformers-inference.

API: POST /vectors {text, config?} → {text, vector, dim}
     GET /.well-known/live → 204
     GET /.well-known/ready → 204
     GET /meta → model info

NOTE: This service is created by ProxLab Helper Scripts and is NOT made by
or associated with Weaviate or SeMI Technologies.
"""

import os
import sys
import logging
from contextlib import asynccontextmanager

import torch
import uvicorn
from fastapi import FastAPI, Response
from pydantic import BaseModel, Field
from sentence_transformers import SentenceTransformer

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("t2v-transformers")

MODEL_NAME = os.environ.get("MODEL_NAME", "sentence-transformers/all-MiniLM-L6-v2")
MODEL_PATH = os.environ.get("MODEL_PATH", "./models/model")
PORT = int(os.environ.get("PORT", "8080"))
ENABLE_CUDA = os.environ.get("ENABLE_CUDA", "0") == "1"

model: SentenceTransformer = None


class VectorRequest(BaseModel):
    model_config = {"extra": "allow"}
    text: str
    config: dict = Field(default_factory=dict)


class VectorResponse(BaseModel):
    text: str
    vector: list[float]
    dim: int


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    device = "cuda" if ENABLE_CUDA and torch.cuda.is_available() else "cpu"
    log.info(f"Loading model: {MODEL_NAME} on {device}")

    if os.path.isdir(MODEL_PATH):
        model = SentenceTransformer(MODEL_PATH, device=device)
        log.info(f"Loaded model from cache: {MODEL_PATH}")
    else:
        model = SentenceTransformer(MODEL_NAME, device=device)
        os.makedirs(os.path.dirname(MODEL_PATH), exist_ok=True)
        model.save(MODEL_PATH)
        log.info(f"Downloaded and cached model to {MODEL_PATH}")

    log.info(f"Model ready — dim={model.get_sentence_embedding_dimension()}")
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
        "type": "sentence-transformers",
    }


@app.post("/vectors", response_model=VectorResponse)
@app.post("/vectors/", response_model=VectorResponse)
async def vectorize(req: VectorRequest):
    try:
        embedding = model.encode(req.text, normalize_embeddings=True)
        vec = embedding.tolist()
        return VectorResponse(text=req.text, vector=vec, dim=len(vec))
    except Exception as e:
        log.error(f"Vectorization error: {e}")
        return Response(content=f'{{"error": "{e}"}}', status_code=500, media_type="application/json")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
