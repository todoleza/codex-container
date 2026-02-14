#!/bin/bash
set -x
npm pack @openai/codex
ln -srf $(ls -t openai-codex-*.tgz | head -1)  dist/codex.tgz
