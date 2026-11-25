terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0.0"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}


# Resource groups
resource "azurerm_resource_group" "main" {
  name     = "rg-backup-${var.yourname}"
  location = var.location
  tags     = var.tags
}

# RBAC role to allow the current user to upload to the documents container
resource "azurerm_role_assignment" "backup_test_uploader" {
  scope                = "${azurerm_storage_account.backup.id}/blobServices/default/containers/documents"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Blob storage
resource "azurerm_storage_account" "backup" {
  name                     = "stbackup${var.yourname}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = var.tags
}

# Storage containers
resource "azurerm_storage_container" "documents" {
  name                  = "documents"
  storage_account_id    = azurerm_storage_account.backup.id
  container_access_type = "private"

}

resource "azurerm_storage_container" "database_exports" {
  name                  = "database-exports"
  storage_account_id    = azurerm_storage_account.backup.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "application_files" {
  name                  = "application-files"
  storage_account_id    = azurerm_storage_account.backup.id
  container_access_type = "private"
}

# Data lifecycle policies
resource "azurerm_storage_management_policy" "lifecycle" {
  storage_account_id = azurerm_storage_account.backup.id

  rule {
    name    = "backup-lifecycle"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["documents/", "database-exports/", "application-files/"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_archive_after_days_since_modification_greater_than = 90
        delete_after_days_since_modification_greater_than          = 365
      }

      version {
        delete_after_days_since_creation = 30
      }
    }
  }
}

# Log analytics workspace 
resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-backup-${var.yourname}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# Log analytics workspace settings to collect diagnostics and logs
resource "azurerm_monitor_diagnostic_setting" "storage_logs" {
  name                       = "diag-storage-to-law"
  target_resource_id         = "${azurerm_storage_account.backup.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "StorageRead" }
  enabled_log { category = "StorageWrite" }
  enabled_log { category = "StorageDelete" }

  enabled_metric {
    category = "Transaction"
  }
}

# Action group and Logic app for automated backup notifications
resource "azurerm_monitor_action_group" "backup_alerts" {
  name                = "ag-backup-${var.yourname}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "backupalert"

  email_receiver {
    name                    = "owner-email"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }

  tags = var.tags
}

resource "azurerm_logic_app_workflow" "backup_confirmation" {
  name                = "la-backup-confirm-${var.yourname}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

# Monitor alerting 
resource "azurerm_monitor_metric_alert" "no_writes" {
  name                = "alert-no-backup-writes"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_storage_account.backup.id]
  description         = "Fires if no files have been written to backup storage in 24 hours."
  severity            = 2
  frequency           = "PT1H"
  window_size         = "P1D"

  criteria {
    metric_namespace = "Microsoft.Storage/storageAccounts"
    metric_name      = "Transactions"
    aggregation      = "Total"
    operator         = "LessThan"
    threshold        = 1

    dimension {
      name     = "ApiName"
      operator = "Include"
      values   = ["PutBlob", "PutBlock"]
    }

    dimension {
      name     = "ResponseType"
      operator = "Include"
      values   = ["Success"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.backup_alerts.id
  }

  tags = var.tags
}




