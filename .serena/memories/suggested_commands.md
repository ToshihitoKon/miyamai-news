# 実行コマンド

## CLI本体（bundler/inlineで依存自動取得、bundle install不要）
サブコマンド必須（省略時はhelpを出して終了）。handoffを境に実行環境が分かれる:
draft（AI環境: 収集〜台本〜R2 handoff）/ synthesize（VOICEPEAK環境）/ publish。
工程はdigest/script/handoff/synthesize/publishで、`config.yaml`の`pipeline.until`（既定digest。
旧キー`pipeline.mode`はエラー）がその環境で進んでよい上限を決める。

```sh
ruby miyamai_news.rb draft                   # 台本一式をR2のhandoff/に置くまで
ruby miyamai_news.rb draft --until digest    # ニュース選別・facts抽出まで
ruby miyamai_news.rb draft --until script    # 台本（TTS整形前）まで（work/に書き出す、確認・手直し用）
ruby miyamai_news.rb synthesize              # R2の台本から音声合成・BGM合成（dist/に書き出して終了）
ruby miyamai_news.rb publish                 # dist/の該当回を公開
ruby miyamai_news.rb synthesize-and-publish  # synthesize → publish
ruby miyamai_news.rb draft-and-publish       # draft → synthesize → publish
ruby miyamai_news.rb clean                # work/を掃除し、公開済みのdist/成果物を削除
ruby miyamai_news.rb clean --archive      # archived/配下の退避済み成果物を完全削除
ruby miyamai_news.rb republish-ui         # 新しい回を公開せずindex.html/manifest.jsonだけ再生成
ruby miyamai_news.rb synthesize-and-publish --date 2026-07-10 --slot morning  # 対象回を明示
ruby miyamai_news.rb --help             # オプション一覧を表示
```

## テスト・Lint（Gemfile経由、こちらはbundle install必要）
```sh
bundle exec rspec              # 全テスト実行
bundle exec rspec spec/script_generator_spec.rb  # 特定ファイルのみ
bundle exec rubocop            # lint
```

## Darwin固有の注意
- VOICEPEAKは `/Applications/voicepeak.app/Contents/MacOS/voicepeak` のGUIアプリバイナリ。連続起動するとクラッシュするため`config.yaml`の`voicepeak.interval_sec`で間隔を空けている（詳細は`mem:script_generator`ではなくvoice_synthesizer側の実装を参照）。
