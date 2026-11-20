# MiMo 离线录制

`pool-model-evaluation.json` 来自 2026-11-05 #9 最终轮，包含 7 次实际最终文本回复、服务端 token usage、候选与逐句证据。`pool-model-material.json` 是 #8 的固定资料输入。未保存请求头、密钥或思考内容。

用于解码、原文提示词不变、原文核对、完整管线和按需持久缓存回放；测试不请求外网。录制中存在额外不完整 check，覆盖真实容错修复。测试重放通过只证明行为可重现；选中故事的人工质量问题见 `Research/StoryModelEval/p5c/summary.md`，不把这些输出当作已审核的正确文案。
