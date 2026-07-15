# タスク完了時に実行すべきコマンド

コード変更後は以下を実行して確認する:

```sh
bundle exec rspec      # テストが通ることを確認
bundle exec rubocop    # lintエラーがないことを確認
```

`lib/`配下や`miyamai_news.rb`を変更した場合、可能なら実際に `ruby miyamai_news.rb --script-only` 等の軽量オプションで実際の動作確認も行う（ただしAI CLI呼び出しやVOICEPEAK合成が絡むため、コストや副作用に注意）。
