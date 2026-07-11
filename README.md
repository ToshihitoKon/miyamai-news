# 宮舞モカ ニュース番組パイプライン

技術ニュースを RSS で収集し、台本生成 → 音声合成（VOICEPEAK 宮舞モカ）→ BGM 合成まで一貫して行い、
GCS 上のペライチ再生ページと Atom フィードを更新する。

## 構成

各工程はコンポーネントとして `lib/` 以下に分かれ、`miyamai_news.rb` はそれらを
束ねる薄いエントリポイントに徹する。

| ファイル | 役割 |
| --- | --- |
| `miyamai_news.rb` | エントリポイント。CLI 解析と工程のオーケストレーション |
| `lib/script_generator.rb` | 台本生成（RSS 収集 → ライター → VOICEPEAK 向け整形） |
| `lib/voice_synthesizer.rb` | 台本を VOICEPEAK（宮舞モカ）で音声合成 |
| `lib/audio_mixer.rb` | ナレーションに BGM を当てて完成版 mp3 を書き出す |
| `lib/publisher.rb` | 完成版 mp3 を GCS に置き、再生ページ / フィードを更新 |
| `lib/config.rb` | `config.yaml` を読み込む共有ローダー |
| `lib/template_renderer.rb` | `templates/` の ERB を描画する共有ローダー |
| `lib/slot.rb` | 実行時刻から時間帯 slot を決める |
| `config.sample.yaml` | 設定のサンプル。これを元に `config.yaml` を作る |
| `templates/` | プロンプト（`*.prompt.erb`）と再生ページ / フィード（`*.erb`） |
| `Makefile` | `run` / `generate` / `upload` / `clean` の入り口 |

プロンプトとページ / フィードのマークアップはすべて `templates/` に外出ししてあり、
文面やデザインの調整は Ruby に触れず `templates/` 内で完結する。

## セットアップ

### 1. 設定ファイル

環境依存する値（VOICEPEAK のパス、BGM・カバー画像、GCS バケット名など）は
すべて `config.yaml` に集約している。サンプルからコピーして値を埋める。

```sh
cp config.sample.yaml config.yaml
# エディタで config.yaml を開き、環境に合わせて書き換える
```

`config.yaml` は git 管理外。各項目の意味は `config.sample.yaml` のコメントを参照。

### 2. 素材の用意

BGM・カバー画像はリポジトリに含めていない。各自で用意し、`config.yaml` の
`assets.bgm_path` / `assets.cover_image` にパスを設定する。

- **BGM**: 任意の音源。既定では猫きまぐれBGM工房様の「古びた魔法書」を利用（<https://kim4gure.com/>）
- **カバー画像**: 横長バナー。Slack のリンクプレビューと再生ページで使う。
  事前に `gs://<bucket>/<cover_image>` へ手動アップロードしておく

### 3. 依存ツール

- Ruby（`.tool-versions` 参照）。gem は `bundler/inline` で自動取得
- [VOICEPEAK](https://www.ah-soft.com/voice/moca/)（宮舞モカ）
- `ffmpeg`（BGM 合成）
- `gcloud`（認証・プロジェクト設定済み。バケットは公開読み取り可）

## 使い方

```sh
make run                 # 生成→公開まで一気通し
make generate            # 台本→音声→BGM合成のみ。成果物は dist/ へ
make upload              # dist/ の該当回 mp3(+used.txt) を GCS へ公開
make clean               # work/ を初期化し、公開済みの dist/ 成果物を削除
```

日付・時間帯を指定する場合:

```sh
make upload DATE=20260710 SLOT=morning   # SLOT: morning / afternoon / evening
make generate BGM=path/to/bgm.mp3        # BGM を一時的に差し替え
```

`miyamai_news.rb` を直接叩く場合:

```sh
ruby miyamai_news.rb                  # 生成→公開まで一気通し
ruby miyamai_news.rb --generate-only  # 生成のみ（dist/ に書き出して終了）
ruby miyamai_news.rb --publish-only   # dist/ の該当回を公開のみ
ruby miyamai_news.rb --clean          # 中間生成物（work/）を初期化
# --bgm PATH / --date YYYY-MM-DD / --slot morning|afternoon|evening で対象を指定
```

時間帯 `slot` は実行時刻から自動で決まる（morning=0〜11時 / afternoon=12〜17時 / evening=18時〜）。
1日に複数回まわしてもファイル名が衝突せず、別エピソードとして共存する。
