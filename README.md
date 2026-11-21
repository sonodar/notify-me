# notify-me

プログラムからの通知を、メールではなく **LINE** で受け取るための最小構成です。

プログラム側は `sns publish` するだけ。あとは裏側が吸収します。

```
[Your program]
      |  aws sns publish
      v
[SNS Topic: notify-me]
      |
      v
[SQS Queue: notify-me] --(3回失敗)--> [DLQ: notify-me-dlq]
      |
      v
[Lambda: line-notifier] --> LINE Messaging API (Push) --> あなたのLINE
```

> **LINE Notify は使っていません。** LINE Notify は2025年3月31日にサービス終了しました。本構成は後継の **LINE Messaging API（Push）** を使います。

## 特徴

- **取りこぼしなし寄りの設計**: SNS と Lambda の間に SQS を挟むので、LINE API の一時障害時はキューに残って自動リトライされ、最終的に失敗したものは DLQ に落ちます（消えません）。
- **重複防止**: Lambda の再試行時に同じ通知が二重に届かないよう、`X-Line-Retry-Key` に SQS MessageId 由来の UUID を使います（24時間有効）。
- **部分失敗応答**: SQS バッチ内の一部だけ失敗した場合、そのレコードだけを再試行対象として返します（`ReportBatchItemFailures`）。
- **恒久エラーは捨てる**: ブロック済み・不正な宛先など、再試行しても直らない 4xx（429除く）はログに残して破棄し、無駄なリトライをしません。
- **秘密情報は SSM に集約**: チャネルアクセストークン等は Terraform の state に入れず、SSM Parameter Store（SecureString）に置きます。Terraform はプレースホルダを作るだけです。
- **追加ライブラリ不要**: Lambda は Python 標準ライブラリ（`urllib`）+ `boto3`（ランタイム同梱）のみ。

## 前提

- AWS アカウント
- Terraform >= 1.5、AWS CLI
- LINE Developers アカウント
- 月の通知数が無料枠に収まる見込み（後述）

## パラメータ一覧（個人の値はコードに書かない）

個人ごとに変わる値・秘密情報は、すべてパラメータとして外から渡します。リポジトリ内のコード／Terraform／ドキュメントに実値を書く場所はありません。

| パラメータ | 中身 | 置き場所 | 渡し方 |
| --- | --- | --- | --- |
| チャネルアクセストークン | LINE Messaging API（長期） | SSM `/${name_prefix}/channel-access-token`（SecureString） | デプロイ後に `aws ssm put-parameter --overwrite`（手順3） |
| チャネルシークレット | Webhook 署名検証用 | SSM `/${name_prefix}/channel-secret`（SecureString） | 同上 |
| userId | 通知先の LINE ユーザーID（`U...`） | SSM `/${name_prefix}/user-id` | Webhook で取得してから `put-parameter`（手順4） |
| `aws_region` | デプロイ先リージョン | Terraform 変数 | `terraform.tfvars`（`terraform.tfvars.example` をコピー） |
| `name_prefix` | リソース名と SSM パスの接頭辞 | Terraform 変数 | 同上。デフォルトは `notify-me` |
| AWS アカウント ID | ARN 等に含まれる | **どこにも書かない** | Terraform が `aws_caller_identity` で実行時に取得 |
| Topic ARN / Queue URL | プログラム側の送信先 | Terraform の出力 | 呼び出し側プログラムへ環境変数等で渡す（`.env.example` 参照） |

Terraform の state に秘密情報を入れないため、Terraform は SSM パラメータの器（プレースホルダ値）だけを作り、実値は CLI で上書きします（`lifecycle.ignore_changes` で巻き戻り防止済み）。

## 料金の目安

- AWS 側: SNS / SQS / Lambda / SSM Parameter Store は、個人の通知量なら無料枠の範囲でほぼ収まります。
- LINE 側: Push は公式アカウントのメッセージ通数にカウントされます。無料のコミュニケーションプランは **月200通** までです。宛先が自分1人なら「通知回数 = 通数」です。200回/月を超える使い方では、ライトプラン（月5,000円・5,000通）等が必要になります。

## セットアップ

### 1. LINE 側: Messaging API チャネルを作る

1. [LINE Developers コンソール](https://developers.line.biz/console/) でプロバイダーを作成（既存でも可）。
2. **Messaging API チャネル** を新規作成し、紐づく LINE 公式アカウントを用意する。
3. チャネル基本設定で **チャネルシークレット** を控える。
4. Messaging API 設定で **チャネルアクセストークン（長期）** を発行して控える。
5. 応答設定で「あいさつメッセージ」「応答メッセージ」を **オフ** にする（通知専用のため）。
6. 公式アカウントを自分の LINE で **友だち追加** する（QRコードは Messaging API 設定画面にあります）。

### 2. AWS 側: デプロイ

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars を自分の値に編集する（aws_region / name_prefix / enable_webhook）
terraform init
terraform apply
```

出力の `webhook_url`、`sns_topic_arn`、`sqs_queue_url` を控えます。

### 3. 秘密情報を SSM に入れる

Terraform が作ったプレースホルダを、実際の値で上書きします。**トークンを Git やチャットに貼らないでください。**

```bash
# 値は自分の環境のものに置き換える（このファイルには実値を残さない）
REGION='<your AWS region>'            # terraform.tfvars の aws_region と同じ値
PREFIX='<your name_prefix>'           # terraform.tfvars の name_prefix と同じ値（デフォルト: notify-me）

aws ssm put-parameter --region "$REGION" --overwrite \
  --name "/$PREFIX/channel-access-token" \
  --type SecureString --value '<your long-lived channel access token>'

aws ssm put-parameter --region "$REGION" --overwrite \
  --name "/$PREFIX/channel-secret" \
  --type SecureString --value '<your channel secret>'
```

### 4. 自分の userId を取得する

Push の宛先 `userId` は、LINE アプリに表示される ID とは別の、チャネル固有の `U` で始まる文字列です。同梱の Webhook Lambda で取得します。

1. LINE Developers コンソール → 対象チャネル → Messaging API 設定 → **Webhook URL** に、Terraform 出力の `webhook_url` を設定し、Webhook の利用を **オン** にする。「検証」ボタンで成功することを確認。
2. 公式アカウントに何かメッセージを送る（友だち追加済みなら送信だけで可）。
3. CloudWatch Logs で userId を拾う:

```bash
aws logs filter-log-events --region "$REGION" \
  --log-group-name "/aws/lambda/$PREFIX-webhook" \
  --filter-pattern 'USER_ID_CAPTURED' \
  --query 'events[].message' --output text
# => USER_ID_CAPTURED U... event_type=message
```

4. 拾った userId を SSM に入れる:

```bash
aws ssm put-parameter --region "$REGION" --overwrite \
  --name "/$PREFIX/user-id" \
  --type String --value '<captured userId>'
```

5. （任意）取得が終わったら Webhook は不要です。`terraform apply -var="enable_webhook=false"` で撤去できます。

> Lambda は SSM の値をコールドスタート時に読むため、SSM を更新した直後は古いコンテナが残っている場合があります。テスト前に一度、通知用 Lambda の設定を軽く触る／しばらく待つ等で新しい実行環境に切り替えてください。

### 5. テスト送信

```bash
TOPIC_ARN=$(terraform output -raw sns_topic_arn)

aws sns publish \
  --topic-arn "$TOPIC_ARN" \
  --subject 'Test' \
  --message 'notify-me のテスト通知です'
```

数秒以内に LINE に届けば完了です。プログラムからは、この Topic ARN に対して publish するだけです。

SQS へ直接送ることもできます:

```bash
QUEUE_URL=$(terraform output -raw sqs_queue_url)
aws sqs send-message --queue-url "$QUEUE_URL" --message-body '直接キューのテスト'
```

## プログラムからの使い方

### AWS CLI

```bash
aws sns publish --topic-arn "$TOPIC_ARN" \
  --subject 'Batch finished' --message 'job=42 status=ok'
```

### Python (boto3)

```python
import os

import boto3

# 送信先とリージョンは環境変数で渡す（terraform output の値を設定する）
sns = boto3.client("sns", region_name=os.environ["AWS_REGION"])
sns.publish(
    TopicArn=os.environ["SNS_TOPIC_ARN"],
    Subject="Batch finished",
    Message="job=42 status=ok",
)
```

必要な IAM 権限は、対象 Topic への `sns:Publish` のみです（直接キュー送信なら対象 Queue への `sqs:SendMessage` のみ）。LINE のトークンをプログラム側に渡す必要はありません。

## メッセージ形式

Lambda は以下の入力を解釈します。

| 入力 | 扱い |
| --- | --- |
| SNS 経由（件名あり） | 1行目が件名、続けて本文 |
| SNS 経由（Message が JSON） | JSON を整形して本文にする（AWS サービス通知向け） |
| SQS 直接・プレーンテキスト | そのまま本文 |
| SQS 直接・JSON `{"subject"/"title", "message"/"text"}` | 件名＋本文として整形 |

本文が LINE の上限（5,000文字）を超える場合は分割して送り、収まらない分は切り捨ててその旨を末尾に付けます。

## 運用メモ

- **届かないとき**: まず DLQ を確認してください。恒久エラーで破棄されたものは通知用 Lambda の CloudWatch Logs に `DROP` として残ります。再試行中は `RETRY` ログが出ます。
- **DLQ の中身を見る**:

```bash
DLQ_URL=$(terraform output -raw sqs_dlq_url)
aws sqs receive-message --queue-url "$DLQ_URL" --max-number-of-messages 10
```

- **通知が多すぎる場合**: 無料枠は月200通です。プログラム側で重要度による間引きや集約（例: 完了通知だけ送る）を入れてください。本構成は 1 publish = 1 Push が前提です。

## 構成ファイル

```
lambda/handler.py           # 本体: SQS -> LINE Push
lambda/webhook_handler.py   # userId 取得専用 Webhook
terraform/                  # SNS / SQS + DLQ / Lambda / SSM / IAM
examples/                   # 送信テスト用スクリプト
tests/                      # handler のユニットテスト
```

## テスト

```bash
python3 -m unittest discover -s tests -v
```

## ライセンス

MIT
