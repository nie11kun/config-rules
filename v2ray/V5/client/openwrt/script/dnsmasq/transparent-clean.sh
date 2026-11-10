#!/usr/bin/env bash

# 删除路由表（表不存在时忽略报错）
nft delete table ip v2ray 2>/dev/null