# コーディング規約・設計パターン

- コメントは「なぜ」を書く方針が徹底されている（readable_codeルールと一致）。自明な処理には付けず、ハマりどころ・トレードオフ・後方互換上の理由がある箇所にのみ付与。
- 中間ファイルの再利用パターン: `script_generator.rb`の各ステップ（収集・選定・facts抽出・台本執筆・整形）は、対応する中間ファイル（`work/`配下）の存在有無で再利用を判断する。途中クラッシュ後の再実行で続きから進められる設計。新しいステップを追加する際もこのパターンを踏襲する。
- AI CLIへの出力後処理: AIが生成したテキストには前置き・思考メモが混入することがあるため、`strip_preamble`/`strip_used_preamble`/`strip_facts_preamble`のような機械的な除去処理をRuby側で必ずかける。プロンプトでの指示だけでは防ぎきれない前提。
- `rewrite_file`は書き込み先ファイルが存在しない場合`abort`する（不完全な状態のまま後工程に進ませない）。
- config値の読み出しは`Config.get("a.b.c")`形式のドット区切りパス（`lib/internal/config.rb`）。
- Rubyバージョン4.0系のendless method定義（`def foo = bar`）を多用（例: `script_generator.rb`のパスヘルパー群）。
- CLIオプション解析は標準の`OptionParser`を使用（2026-07-14に手書きARGVパーサーから移行済み、PR #18）。
