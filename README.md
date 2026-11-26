# ops-lab：AI に障害調査させる運用基盤のデモ

> 作成中です（2026年11月〜）。構築と検証の進み具合に合わせて、検証結果をこの README と `docs/verification-log.md` に追記していきます。

小さな注文API と、それを見張る監視基盤、そして AWS DevOps Agent による自動調査をひとまとめにしたデモ環境です。
中小企業でも無理なく持てる「AI 監視パッケージ」を想定して作りました。

- 監視の設定は Terraform でコード化し、誰が作っても同じ構成になるようにしています
- 障害を3種類わざと起こせるようにして、AI の調査精度を検証できるようにしています
- DevOps Agent にはスキルとルール（AGENTS.md）を渡し、「教えると精度が上がるか」を記録しています
- すべて AWS の常時無料枠があるサービスで構成し、無料プランの範囲で動かしています
- 設計と実装には AI エージェント（Claude）を使いました。何を検証するか、どの結果をどう読むかを決めるのが自分の役割です

## 構成

```mermaid
flowchart LR
  user[お客さん / load.py] -->|POST /orders| apigw[API Gateway<br>HTTP API]
  apigw --> lambda[Lambda<br>ops-lab-order-api]
  lambda --> ddb[(DynamoDB<br>ops-lab-orders)]
  lambda -.設定を読む.-> ssm[SSM パラメータ<br>決済タイムアウト]
  lambda --> logs[CloudWatch Logs]
  apigw --> cw[CloudWatch<br>メトリクス・アラーム]
  ddb --> cw
  logs --> cw
  cw --> sns[SNS トピック]
  sns --> mail[メール通知]
  sns --> agent[AWS DevOps Agent<br>自動調査]
  agent -.スキル・AGENTS.md.-> agent
```

## 設計で考えたこと

- 人と AI の役割分担を決めた。AI（DevOps Agent）は調査と提案だけで、変更は人が承認して行う。エージェントには変更の権限を付けていない。
- AI には推測で埋めさせない。スキルの中で「値が取れなければ null」「説明文だけで原因を決めない」を明示し、報告は決まった JSON 形式で出させる。
- ログはすべて JSON 1行で出す。Logs Insights の保存クエリで、人も AI も同じ切り口で集計できる。
- 障害シナリオ1の設定値は Terraform の管理から外している（`ignore_changes`）。手作業で変えられた値を、次の apply で黙って戻さないためで、実際の運用でもよく起きる「コードと実環境のずれ」を再現している。
- 予算アラートとログの保存期間（7日）を最初から入れ、放置しても費用が膨らまないようにした。

## フォルダ構成

| パス | 中身 |
|---|---|
| `app/order_api/handler.py` | 注文API（Python）。障害を起こす仕掛け入り |
| `app/tests/` | テスト（moto で AWS を模擬。AWS につながずに動く） |
| `infra/` | Terraform（API・DB・設定・アラーム・ダッシュボード・通知・予算） |
| `tools/load.py` | 注文の負荷をかけるスクリプト |
| `tools/chaos.sh` | 障害シナリオを起こす・戻すスクリプト |
| `agent/AGENTS.md` | DevOps Agent に常に守らせるルール |
| `agent/skills/order-api-incident/SKILL.md` | 調査手順のスキル |
| `docs/scenarios.md` | 障害シナリオの台本と正解 |
| `docs/verification-log.md` | 検証結果の記録 |

## 動かし方

### 必要なもの

- Terraform 1.6 以上
- AWS CLI v2（管理者の IAM ユーザーでログインできること。ルートユーザーでは作業しない）
- Python 3.10 以上

### 1. テスト（AWS につながずに確認）

```bash
pip install pytest "moto[dynamodb,ssm]" boto3
cd app && python -m pytest -q
```

### 2. デプロイ

```bash
aws login                     # 使えない場合は aws configure sso など
aws sts get-caller-identity   # 自分の IAM ユーザーになっているか確認
cd infra
cp terraform.tfvars.example terraform.tfvars   # 通知先メールを入れる
terraform init
terraform plan                # 作られるものを目で確認する
terraform apply
```

メール通知を設定した場合は、届いた確認メールのリンクを押して購読を有効にしてください。

### 3. 障害を起こして調査させる

```bash
python tools/load.py --url "$(terraform -chdir=infra output -raw api_url)" --minutes 10
./tools/chaos.sh config-mistake   # 別のターミナルで
# アラームが鳴ったら DevOps Agent に調査させる
./tools/chaos.sh reset
```

詳しくは [docs/scenarios.md](docs/scenarios.md) を見てください。

### 4. DevOps Agent の設定

1. DevOps Agent のコンソールで Agent Space を作る（エージェントアクションは無効のまま）
   - Terraform で作ったリソースを構成図（トポロジー）に載せるには、同じリージョンで AWS Resource Explorer を有効にしておく（CloudFormation で作ったものでないと、Resource Explorer 経由で見つけるため）
2. `agent/AGENTS.md` と `agent/skills/order-api-incident/SKILL.md` をナレッジとスキルに登録する
3. アラームから自動で調査させる場合は、Agent Space の Webhook を発行し、SNS トピック（`terraform output alerts_topic_arn`）とつなぐ
4. 調査結果が外れたら、フィードバック機能で正解を教える

### 5. 片付け

```bash
cd infra && terraform destroy
```

## 検証結果（途中経過）

| シナリオ | スキル | 結果 |
|---|---|---|
| 1 設定ミス | なし | 約4分で根本原因（SSM パラメータの手動変更）を特定。再デプロイ不要と判断し、再発防止策まで提案 |
| 2 不具合のあるリリース | なし | 約5分で特定。「v1.4.0 のリリース」に見えても、コードのハッシュが同じことから「変わったのは設定だけ、コードの戻しは不要」と判断 |
| 3 DB の容量不足 | なし | 約4分半で書き込み容量の引き下げ（5→1）を特定。ただし直近のメトリクスの空白を「沈静化した」と誤認 |

| 複合（リリース＋設定ミス） | なし | 約5分で2つの原因を両方特定。「500 はリリース、504 は設定」と対応づけ、「片方だけ戻しても回復しない」と判断 |

| 3 DB の容量不足 | あり | 約5分20秒で特定。スキルなしのときの「沈静化した」という誤認がなくなり、アラームの状態と最新ログの時刻から「継続中」と判断。確かめていない仮説は別の欄に分けて出した |

スキルなしでも4つとも原因は正解でした。スキルとルールで変わったのは正答率ではなく、「今も続いているか」の判断と、推測の扱い方です。スキルなしの結果から誤りの種類を見つけ、それを防ぐルールを書き足して、同じシナリオで直ったことを確かめました。

詳しくは [docs/verification-log.md](docs/verification-log.md) を見てください。

### デプロイ方法のメモ

自分の PC に何もインストールせず、AWS コンソールの CloudShell（ブラウザのターミナル）で `git clone` → `terraform apply` しています。管理者の IAM ユーザーでログインした状態のまま使えるので、アクセスキーを発行せずに済みます。

CloudShell は、しばらく触らないとセッションが切れます。残るのはホームディレクトリ（`~`）だけで、`dnf` で入れた Terraform は消えます。state ファイルは `~/ops-lab/infra` にあるので無事です。入れ直したら `~/bin` にコピーしておくと、次からは入れ直さずに使えます。

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo dnf install -y terraform
mkdir -p ~/bin && cp /usr/bin/terraform ~/bin/   # ホームに置けば次のセッションでも残る
```

## 費用

- 使っているサービスはすべて常時無料枠があり、検証1回（約1,200リクエスト）は無料枠に十分収まります。
- API Gateway に1秒10リクエストの上限をかけ、想定外のアクセスで無料枠を使い切らないようにしています。使わない間は `terraform destroy` で消しておきます。
- 予算アラートは、クレジットで相殺する前の金額で判定するようにしています（無料プランでは相殺後が $0 に見えるため）。
- DevOps Agent は稼働時間の秒単位課金です。無料トライアルの範囲で使っています。

## 参考

- opsmethod#6「DevOpsAgentをチームに迎えて運用しよう」（クラスメソッド大阪、2026/11/25）の各セッションを参考にしました
