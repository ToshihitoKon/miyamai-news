# miyamai_news — プロジェクト概要

技術ニュースをRSS収集 → AI CLIで台本生成 → VOICEPEAK音声合成 → BGM合成 → GCS公開まで一貫実行するRubyパイプライン（キャラクター「宮舞モカ」のニュース番組）。

## 構成原則
- エントリポイントは `miyamai_news.rb`（単一ファイル、`bundler/inline` で依存gemを自動取得）。CLI解析と呼び出し順制御のみを担い、ロジックは持たない。
- `lib/` 配下の各クラスが工程を1つずつ担当: `episode.rb`(番組コンテキスト) → `script_generator.rb`(RSS収集・AI台本生成) → `voice_synthesizer.rb`(VOICEPEAK音声合成) → `audio_mixer.rb`(BGM合成) → `publisher.rb`(GCS公開)。
- `lib/internal/` は汎用ユーティリティ（config, feed_parser, http_fetcher, template_renderer, hatena_bookmarks）。
- プロンプト本文は `templates/*.prompt.erb` に外出し。プロンプト文面の調整はRubyに触れず`templates/`内で完結する設計。
- 設定は `config.yaml`（git管理外、`config.sample.yaml`からコピーして使う）に集約。RSS収集元定義も含めここに全て入る。

## 詳細メモリへの参照
- 技術スタック・依存関係・バージョン: `mem:tech_stack`
- 実行コマンド（テスト・lint・CLI起動）: `mem:suggested_commands`
- コーディング規約・設計パターン: `mem:conventions`
- タスク完了時に走らせるべきチェック: `mem:task_completion`
- 台本生成パイプライン（AI CLI呼び出し、`agy`/`claude`の切り替え、前置き除去処理など）の詳細: `mem:script_generator`
