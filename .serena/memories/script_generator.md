# script_generator.rb — 台本生成パイプライン詳細

## AI CLI呼び出し（`run_ai_cli` / `run_command_with_spinner`）
- `config.yaml`の`ai_agent.bin`で使用CLIを切り替え。`bin == "claude"`かどうかで引数の組み立てが分岐する（`claude`は`--effort`や`--allowedTools`等Claude Code CLI固有引数を渡す。それ以外（例: `agy` = Antigravity CLI, Gemini系）は`--model --dangerously-skip-permissions -p <prompt>`のシンプルな形で呼ぶ）。
- ロールごとに別モデルを指定可能（`selector_model`/`extractor_model`/`writer_model`/`formatter_model`、未指定時は`ai_agent.model`にフォールバック。`get_model_for_role`が解決）。
- 外部CLIは`Open3.capture3`で同期実行し、非ゼロ終了時は`spinner.error("(failed)")` → `warn stderr` → `abort`する。**stderrの内容はそのまま素通しで表示される**ため、「[bin名] (failed)」というスピナー表示に続くエラーメッセージは、miyamai_news自体のコードではなく外部AI CLIバイナリ（agyやclaude）が吐いたものであることが多い。原因調査時は先にRubyコード内をgrepするより先に、そのバイナリ自体のエラー文言かどうかを疑う。

## パイプラインの5ステップ（すべて`ScriptGenerator#generate`から呼ばれる）
1. `load_or_collect_news` — RSS収集（AI呼び出しなし、FeedCache経由）
2. `select_news` — ニュース選定（AI、`--allowedTools Write`）
3. `extract_news_facts` — ファクト抽出（AI、`--allowedTools "WebFetch Write"`）
4. `write_script_and_used` — 台本(script)とused_news書き出し（AI、`--allowedTools "Read Write"`）
5. `format_tts_script` — VOICEPEAK向け整形（AI、`--allowedTools "Read Write"`、`format: true`時のみ）

各ステップはAIに直接ファイルをWriteさせ、Rubyが後から読み直して`strip_*_preamble`系メソッドで前置き除去する設計（AIの出力を直接信用しない）。

## 中間ファイル命名規則（`work/`配下、`@date_tag`・`@slot`で回ごとに分離）
`news_*.txt`（収集） → `news_selected_*.txt`（選定） → `news_facts_*.txt`（抽出） → `script_*.txt` + `news_used_*.txt`（執筆） → `tts_script_*.txt`（整形）
