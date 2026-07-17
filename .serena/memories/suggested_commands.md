# 実行コマンド

## CLI本体（bundler/inlineで依存自動取得、bundle install不要）
```sh
ruby miyamai_news.rb                  # 生成→公開まで一気通し
ruby miyamai_news.rb --script-only    # 台本のみ生成して停止（work/に書き出す、確認・手直し用）
ruby miyamai_news.rb --synthesize-only  # 音声合成・BGM合成のみ（dist/に書き出して終了）
ruby miyamai_news.rb --publish-only   # dist/の該当回を公開のみ
ruby miyamai_news.rb --clean          # work/を掃除し、公開済みのdist/成果物を削除
ruby miyamai_news.rb --ui-only        # 新しい回を公開せずindex.html/manifest.jsonだけ再生成
ruby miyamai_news.rb --date 2026-07-10 --slot morning  # 対象回を明示
```

## テスト・Lint（Gemfile経由、こちらはbundle install必要）
```sh
bundle exec rspec              # 全テスト実行
bundle exec rspec spec/script_generator_spec.rb  # 特定ファイルのみ
bundle exec rubocop            # lint
```

## Darwin固有の注意
- VOICEPEAKは `/Applications/voicepeak.app/Contents/MacOS/voicepeak` のGUIアプリバイナリ。連続起動するとクラッシュするため`config.yaml`の`voicepeak.interval_sec`で間隔を空けている（詳細は`mem:script_generator`ではなくvoice_synthesizer側の実装を参照）。
