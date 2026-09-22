# Generator census

手動更新の snapshot。2026-09-22 時点で `scripts/census.sh` を実行した結果。各 spec の全 OpenAPI operation を include し、operationId が無い場合は `method_path` から導出している。OpenAI は overlay を適用していない upstream spec 全体の値。

| spec | operations | diagnostics | top kinds |
|---|---:|---:|---|
| badhttp | 44 | 0 | — |
| petstore3 | 19 | 0 | — |
| openai | 148 | 107 | untagged union 73; non-object allOf 11; discriminator union 8; multipart 6; missing type 4; conflicting allOf property 2; array without items 2; deepObject query 1 |
