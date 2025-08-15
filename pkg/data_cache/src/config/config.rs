use std::env;
use std::sync::Arc;
use std::time::Duration;

/// Configuration for dataset metadata and table information.
///
/// **Important**: The `schema_name` here refers to the **Iceberg schema namespace**,
/// not Arrow schemas. The distributed caching system uses two separate Arrow schemas:
///
/// 1. **Metadata Schema**: Created by head node for worker coordination
/// 2. **Data Schema**: Converted from Iceberg schema by worker nodes
///
/// This config provides the Iceberg table coordinates that workers use to
/// retrieve the original data schema and convert it to Arrow format.
#[derive(Debug, Clone)]
pub struct DatasetConfig {
    /// Location of Iceberg table metadata (e.g., S3 path to metadata.json)
    pub metadata_loc: String,
    /// Iceberg schema namespace (NOT Arrow schema - used for table identification)
    pub schema_name: String,
    /// Iceberg table name within the schema namespace
    pub table_name: String,
}

/// Comprehensive configuration for the data cache system
/// Consolidates all environment variables used across the application
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct CacheConfig {
    pub dataset: DatasetConfig,
    pub connect_timeout: Duration,
}

impl DatasetConfig {
    pub fn from_env() -> Result<Self, Box<dyn std::error::Error>> {
        let metadata_loc = env::var("METADATA_LOC")?;
        let schema_name = env::var("SCHEMA_NAME")?;
        let table_name = env::var("TABLE_NAME")?;
        Ok(DatasetConfig {
            metadata_loc,
            schema_name,
            table_name,
        })
    }
}

#[allow(dead_code)]
impl CacheConfig {
    pub fn from_env() -> Result<Self, Box<dyn std::error::Error>> {
        let dataset = DatasetConfig::from_env()?;

        // Connection timeout with default of 20 seconds
        let connect_timeout = env::var("CONNECT_TIMEOUT_SECS")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .map(Duration::from_secs)
            .unwrap_or(Duration::from_secs(20));

        Ok(CacheConfig {
            dataset,
            connect_timeout,
        })
    }

    /// Create shared configuration from environment variables
    /// Returns Arc<CacheConfig> for efficient sharing across components
    #[allow(dead_code)]
    pub fn shared_from_env() -> Result<Arc<Self>, Box<dyn std::error::Error>> {
        Ok(Arc::new(Self::from_env()?))
    }

    /// Create a new configuration with custom timeout
    #[allow(dead_code)]
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.connect_timeout = timeout;
        self
    }
}
