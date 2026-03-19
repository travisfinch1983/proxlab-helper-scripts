#!/usr/bin/env python3
"""
Native Weaviate text2vec-model2vec inference service.
Drop-in replacement for cr.weaviate.io/semitechnologies/model2vec-inference.

API: POST /vectors {text, config?} → {text, vector, dim}
     GET /.well-known/live → 204
     GET /.well-known/ready → 204
     GET /meta → model info

NOTE: This service is created by ProxLab Helper Scripts and is NOT made by
or associated with Weaviate or SeMI Technologies.
"""

import os
import logging
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, Response
from pydantic import BaseModel, Field
from model2vec import StaticModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("t2v-model2vec")

MODEL_NAME = os.environ.get("MODEL_NAME", "minishlab/potion-base-8M")
MODEL_PATH = os.environ.get("MODEL_PATH", "./models/model")
PORT = int(os.environ.get("PORT", "8080"))

model: StaticModel = None


class VectorRequest(BaseModel):
    text: str
    config: dict = Field(default_factory=dict)


class VectorResponse(BaseModel):
    text: str
    vector: list[float]
    dim: int


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    log.info(f"Loading model: {MODEL_NAME}")

    if os.path.isdir(MODEL_PATH):
        model = StaticModel.from_pretrained(MODEL_PATH)
        log.info(f"Loaded model from cache: {MODEL_PATH}")
    else:
        model = StaticModel.from_pretrained(MODEL_NAME)
        os.makedirs(MODEL_PATH, exist_ok=True)
        model.save_pretrained(MODEL_PATH)
        log.info(f"Downloaded and cached model to {MODEL_PATH}")

    dim = len(model.encode("test"))
    log.info(f"Model ready — dim={dim}")
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
        "type": "model2vec",
    }


@app.post("/vectors", response_model=VectorResponse)
@app.post("/vectors/", response_model=VectorResponse)
async def vectorize(req: VectorRequest):
    try:
        embedding = model.encode(req.text)
        vec = embedding.tolist()
        return VectorResponse(text=req.text, vector=vec, dim=len(vec))
    except Exception as e:
        log.error(f"Vectorization error: {e}")
        return Response(content=f'{{"error": "{e}"}}', status_code=500, media_type="application/json")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
