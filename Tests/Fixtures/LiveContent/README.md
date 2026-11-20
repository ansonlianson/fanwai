2026-11-09：SHINSEKAIより 的真机公开目录快照、旧空关系缓存，以及当天 Wikidata 真实 union 查询与 Q34861530 响应。不是人为把错误 OR 查询合并成成功结果。用于缓存升级、关系来源和加载顺序回归；无凭据或用户收藏。

`shinsekai-wiki-ano.json` 是本轮实际取得的固定版本 Wikipedia parse 响应，用于复现表格引用遗漏；`shinsekai-resolved.json` 是原生实网关系加载后的公开目录快照。`shinsekai-blocked-materials.json` 记录本轮 Natalie robots.txt 405，只有请求状态和采集结果，无验证挑战内容。可选实网诊断仍会在没有故事时失败；默认离线验证跳过该诊断，不将其算作故事生成成功。
