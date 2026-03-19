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
import json
import logging
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, Response, Request

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("t2v-model2vec")

MODEL_NAME = os.environ.get("MODEL_NAME", "minishlab/potion-base-8M")
MODEL_PATH = os.environ.get("MODEL_PATH", "./models/model")
PORT = int(os.environ.get("PORT", "8080"))

model = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    from model2vec import StaticModel

    log.info(f"Loading model: {MODEL_NAME}")
    model = StaticModel.from_pretrained(MODEL_PATH if os.path.isdir(MODEL_PATH) else MODEL_NAME)
    if not os.path.isdir(MODEL_PATH):
        os.makedirs(MODEL_PATH, exist_ok=True)
        model.save_pretrained(MODEL_PATH)
    dim = len(model.encode("test"))
    log.info(f"Model ready — dim={dim}")
    yield
    log.info("Shutting down")


app = FastAPI(lifespan=lifespan)


@app.get("/.well-known/live", status_code=204)
@app.get("/.well-known/ready", status_code=204)
async def health():
    return Response(status_code=204 if model else 503)


@app.get("/meta")
async def meta():
    return {"model": MODEL_NAME, "type": "model2vec"}


@app.post("/vectors")
@app.post("/vectors/")
async def vectorize(request: Request):
    try:
        body = await request.json()
        text = body.get("text", "")
        vec = model.encode(text).tolist()
        return {"text": text, "vector": vec, "dim": len(vec)}
    except Exception as e:
        log.error(f"Vectorization error: {e}")
        return Response(content=json.dumps({"error": str(e)}), status_code=500, media_type="application/json")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
