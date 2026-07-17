# 技術スタック

- 言語: Ruby 4.0.5（`.tool-versions`、asdf/mise管理）
- 依存管理: 二重構造になっている点に注意。
  - `miyamai_news.rb` 本体は `bundler/inline` で実行時に依存gemを自動取得（エンドユーザーは`bundle install`不要で単体実行できる設計）。
  - リポジトリ直下に `Gemfile`/`Gemfile.lock` も存在するが、これは**RSpecなどテスト実行専用**。本体実行用の`bundler/inline`ブロックと内容を意図的に重複させている（tty-spinner, rss, csv, rexml, dry-struct, dry-types + rspec）。どちらか一方を更新したらもう一方も揃える。
- テスト: RSpec 3.13（`.rspec` で `--format documentation` 指定、CIログ用にドキュメンテーション形式）
- Lint: RuboCop（`.rubocop.yml`、`DisabledByDefault: true` で明示的に有効化したCopのみ適用。Metrics/Migrationは無効化済み）
- 外部コマンド依存: VOICEPEAK（音声合成バイナリ、パスはconfig.yamlで指定）、ffmpeg（BGM合成）、gcloud（GCS認証・アップロード）
- 台本生成に使うAI CLI: `config.yaml`の`ai_agent.bin`で切り替え可能（`claude` = Claude Code CLI、`agy` = Antigravity CLI/Gemini系の外部Goバイナリ）。詳細は `mem:script_generator`
