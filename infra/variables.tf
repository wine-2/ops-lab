# ---- 基本設定 ---------------------------------------------------------
variable "region" {
  description = "使うリージョン（東京）"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "リソース名の頭に付ける名前。タグ Project の値にもなる"
  type        = string
  default     = "ops-lab"
}

# ---- アプリのリリース設定（障害シナリオ2で切り替える）----------------
variable "app_version" {
  description = "アプリのバージョン。ログとダッシュボードに出る"
  type        = string
  default     = "1.3.0"
}

variable "fault_mode" {
  description = "none: 正常 / coupon_bug: クーポン付き注文で落ちるバグ入り"
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "coupon_bug"], var.fault_mode)
    error_message = "fault_mode は none か coupon_bug のどちらかにしてください。"
  }
}

# ---- DB 設定（障害シナリオ3で切り替える）------------------------------
variable "table_write_capacity" {
  description = "DynamoDB の書き込み容量。無料枠は合計 25 まで"
  type        = number
  default     = 5

  validation {
    condition     = var.table_write_capacity >= 1 && var.table_write_capacity <= 10
    error_message = "無料枠を超えないよう 1〜10 の範囲にしてください。"
  }
}

# ---- 通知・予算 -------------------------------------------------------
variable "alert_email" {
  description = "アラームと予算アラートの通知先メール。空なら通知を作らない"
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "月の予算（ドル）。無料プランでは請求は発生しないが、使いすぎに気づくために設定する"
  type        = string
  default     = "1"
}
