# Skill Workflow Dependency Experiments

## 实验目标

- 运行真实 skill，让 agent 在每个 subgoal 开始/结束时调用 harness tool。
- 记录 agent message、tool call、文件写入、数据库验证和其他副作用。
- 从实际副作用中重新发现 subgoal 依赖关系。
- 判断哪些 subgoal 可能并行执行。
- 不使用 SSL 的分析字段作为 ground truth；只用 SSL 定位 skill 来源。

## 三种方法

- 手动想象一次实际执行：
  - GPT in Codex 阅读原始 `SKILL.md`。
  - 想象 agent 实际会如何 inspect、修改、验证。
  - 根据这次“想象运行”整理 subgoals 和依赖。
  - 优点：更接近真实执行，容易补出隐藏的 inspect/pre-flight 节点。
  - 缺点：主观，可复现性弱。

- 使用 SCFG：
  - 从原始 skill 文本生成静态 CFG。
  - 得到 node id、node title、edge set。
  - 放进 prompt，让 agent 沿这些节点调用 `begin_subgoal` / `end_subgoal`。
  - 优点：结构化、可复现，方便 trace 对齐。
  - 缺点：容易继承 markdown 章节结构，把 alternative 场景误看成并行节点。

- 运行 agent 后用副作用探测：
  - 观察每个 subgoal 的 reads/writes/validation。
  - 检查 read-after-write、write-write conflict、共享验证资源。
  - 用实际 tool call 副作用修正或挑战 SCFG 的静态边。
  - 这是最终想验证的核心方法。

## 手动想象 vs SCFG

- 主要差异：隐藏的开头 inspect/pre-flight 节点。
- 实际 agent 通常需要先：
  - 读 `SKILL.md`；
  - 列 workspace；
  - inspect 相关文件；
  - 确认 Docker/DB/env；
  - 理解项目结构。
- 原 skill 往往把这些步骤省略为常识。
- 手动想象会自然补出这个共同依赖。
- SCFG 如果原文没有显式章节，可能不会抽出 inspect 节点。
- 因此：
  - “SCFG 没有边”不等于“实际可并行”。
  - 多个节点可能共同依赖一个未显式表示的 inspect 结果。
  - 后续分析应考虑把早期 read/shell calls 聚类成 pre-flight subgoal。

## 当前实验判断

- `nextjs-performance`
  - 最适合做并行依赖发现。
  - SCFG 近似结构：`N001 -> {N002,N003,N004,N005} -> N006`。
  - 中间节点分别处理 waterfalls、bundle size、server actions、production build。
  - 文件和关注面较独立，像干净的 fork-join。

- `database-migrations`
  - 也适合，但只适合看当前 fixture 激活的子集。
  - 实际涉及：安全添加列、大型数据回填、并发索引、安全删除列、最终检查。
  - 多个节点主要改不同 migration 文件。
  - 适合测试文件级副作用依赖。
  - 注意完整 skill 里有很多框架/场景章节，不全是同一次任务里的并行节点。

- `mysql2postgres`
  - 不适合作为干净 ground truth。
  - 适合做隐藏依赖压力测试。
  - SCFG 上很多节点看似独立。
  - 实际上配置、SQL、Java package、MyBatis mapper、sequence、最终验证互相耦合。
  - 可用来测试副作用分析能否发现 SCFG 漏掉的依赖。

- `test-with-postgres`
  - 不适合测试并行性。
  - 自然流程是 `start postgres -> run tests -> cleanup`。
  - 当前 fixture 主要反复执行 `Running Tests`。
  - 更适合测试失败、重试、workflow status。

## 已观察到的现象

- SCFG 节点不等于实际任务节点。
- markdown 章节可能代表：
  - 顺序步骤；
  - 可并行分支；
  - alternative 场景；
  - checklist/rule；
  - framework-specific recipe。
- Agent 不一定严格按 SCFG 顺序执行。
- Transition warnings 不一定是错误，可能暴露静态 CFG 和实际依赖的差异。
- 模型生成的 subgoal `name` 不可靠。
- 已修复：harness 用 workflow 中的 canonical title 覆盖 `begin_subgoal` 的 name。
- 中文 mojibake 问题已修复：
  - HTTP response body 保留 UTF-8 bytes；
  - backend 直接从 bytes 解 JSON。
- `test-with-postgres` 出现过同一节点先 failed 后 success。
- 当前 workflow status 还不能区分：
  - historical failure；
  - final status；
  - recovered node。

## 当前推荐讨论样例

- 主实验：`nextjs-performance`
- 第二主实验：`database-migrations`
- 压力测试：`mysql2postgres`
- 串行/失败恢复测试：`test-with-postgres`

## 下一步问题

- 是否显式加入 hidden inspect/pre-flight ground truth？
- 如何从 trace 自动识别 read-after-write 依赖？
- 如何区分 independent writes 和 write-write conflict？
- SCFG 是否需要区分 parallel branch 和 alternative branch？
- workflow status 是否要支持 recovered node？
- 是否为每个 skill 人工标注一个 expected dependency graph，用来和自动探测结果比较？
