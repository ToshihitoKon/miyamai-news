# 宮舞モカ ニュース番組パイプライン

技術ニュースを RSS で収集し、台本生成 → 音声合成（VOICEPEAK 宮舞モカ）→ BGM 合成まで一貫して行い、
GCS 上のペライチ再生ページと Atom フィードを更新する。

## 構成

| ファイル | 役割 |
| --- | --- |
| `miyamai_news.rb` | 台本生成 → 音声合成 → BGM 合成。成果物は `dist/` へ |
| `publish.rb` | 生成済み mp3 を GCS に置き、再生ページ / フィードを更新 |
| `config.rb` | `config.yaml` を読み込む共有ローダー |
| `config.sample.yaml` | 設定のサンプル。これを元に `config.yaml` を作る |
| `Makefile` | `generate` / `upload` / `clean` の入り口 |

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
make generate            # 台本→音声→BGM合成。成果物は dist/ へ
make upload              # dist/ の該当回 mp3(+used.txt) を GCS へアップロード
make clean               # work/ を初期化し、アップロード済みの dist/ 成果物を削除
```

日付・時間帯を指定する場合:

```sh
make upload DATE=20260710 SLOT=morning   # SLOT: morning / afternoon / evening
make generate BGM=path/to/bgm.mp3        # BGM を一時的に差し替え
```

時間帯 `slot` は実行時刻から自動で決まる（morning=0〜11時 / afternoon=12〜17時 / evening=18時〜）。
1日に複数回まわしてもファイル名が衝突せず、別エピソードとして共存する。
