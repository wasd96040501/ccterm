<!--
DELETE THIS FILE BEFORE MERGING TO MAIN.
Tracking remaining work for PR #114.
-->

# 剩余待解决问题

## 1. Read / codeblock 高亮回填失效

打开 app 后,Read child 展开看不到语法高亮;同时 codeblock 也没有高亮(用户报告)。需要在 app 里实际跑一遍定位 token 是否生成、是否回填到 storage、layout 是否被刷新。

## 2. 软换行行号没和第一行 baseline 对齐

`DiffLayout` 的多行 wrap row,行号渲染位置不是用户期望的「跟第一行 baseline 对齐」。用户描述当前看起来像「跟整个多行中心对齐」。需要实际截图确认现状,然后修到和单行的对齐方式一致(改单行也行,反正最后一致)。
