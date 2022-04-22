FROM ubuntu:20.04

ENV TZ="Europe/Zurich"

RUN apt-get update && apt-get install -y \
  tzdata \
  mpich \
  python3 \
  python3-venv \
  && rm -rf /var/lib/apt/lists/*

COPY . /src/app/
