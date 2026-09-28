# kami-skills

Agent skills from shipping a commercial Apple-platform app, [Huiliu Live (汇流直播)](https://conflux.kami.asia). Each skill captures a problem we hit in production, the fix we shipped and the test checklist that goes with it. They follow the [Claude Skills](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview) format (`SKILL.md` + progressive-disclosure references), so they work in Claude Code, Claude.ai and any agent that reads `SKILL.md`.

## Skills

| Skill | What it's for |
|---|---|
| [`storekit-account-switch-entitlements`](skills/storekit-account-switch-entitlements/SKILL.md) | Keeping StoreKit 2 in-app purchase entitlements from disappearing when users switch App Store accounts or regions. Covers the mental model, the policy choice, a bounded on-device retention pattern with its invariants, user-facing copy and a test matrix. |

## Install

Claude Code, for every project:

```bash
git clone https://github.com/bulai0408/kami-skills.git
cp -R kami-skills/skills/storekit-account-switch-entitlements ~/.claude/skills/
```

For one project only, copy the skill into `<project>/.claude/skills/` instead. The skill loads automatically when a task matches its description, and you can also invoke it by name.

## 中文说明

这里收录的是我们在做商业 Apple 全平台 App 时，从真实线上问题中沉淀出来的 agent skill。

`storekit-account-switch-entitlements` 解决的是「换区掉权益」：用户用外区 Apple 账号购买后切回本区账号，StoreKit 查不到交易，恢复购买也无效。内容包括问题成因，如何区分同账号改区和换账号，三种策略怎么取舍，经过生产验证的「本机快照 + 有界保留」方案及其全部不变量，面向用户的提示文案，以及单元测试和沙盒走查清单。

## License

MIT
