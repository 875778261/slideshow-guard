// 由 home 的 scripts/install-commit-convention.ps1 生成。
// 规则值来自 D:\workspace\home\docs\standards\commit-convention.md
// 二者不一致时以规范正文为准，并重新执行安装脚本。
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'header-max-length': [2, 'always', 72],
    'subject-full-stop': [2, 'never', '。'],
    'subject-case': [0],
    'body-max-line-length': [1, 'always', 100],
    'type-enum': [2, 'always', ['feat', 'fix', 'refactor', 'chore', 'style', 'docs']],
    'scope-enum': [1, 'always', ['guard', 'install', 'docs']],
  },
};