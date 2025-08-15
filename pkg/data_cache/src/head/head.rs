use super::config::config::CacheConfig;
use crate::head::provider::DataFileTableProvider;
use crate::head::writer::DistributedWriterExec;
use arrow::array::UInt64Array;
use arrow_schema::SchemaRef;
use datafusion::datasource::MemTable;
use datafusion::error::{DataFusionError, Result};
use datafusion::physical_expr::Partitioning;
use datafusion::physical_plan::execute_stream;
use datafusion::physical_plan::repartition::RepartitionExec;
use datafusion::prelude::SessionContext;
use datafusion::sql::TableReference;
use futures::StreamExt;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::interval;
use tracing::{error, info, warn};

pub struct Distributor {
    ctx: Arc<SessionContext>,
    num_workers: usize,
    data_file_provider: Arc<DataFileTableProvider>,
    mem_table_name: String,
    worker_map: Arc<HashMap<String, String>>,
    metadata_schema: SchemaRef,
    pub(crate) total_row_count: i64,
    config: Arc<CacheConfig>,
    retry_task_handle: Option<tokio::task::JoinHandle<()>>,
}

impl Distributor {
    pub fn new(
        ctx: Arc<SessionContext>,
        num_workers: usize,
        data_file_provider: Arc<DataFileTableProvider>,
        mem_table_name: String,
        worker_map: Arc<HashMap<String, String>>,
        metadata_schema: SchemaRef,
        config: Arc<CacheConfig>,
    ) -> Self {
        Self {
            ctx,
            num_workers,
            data_file_provider,
            mem_table_name,
            worker_map,
            metadata_schema,
            total_row_count: 0,
            config,
            retry_task_handle: None,
        }
    }

    pub async fn init(&mut self) -> Result<()> {
        let _ = self.fetch_data_files().await;
        let df = self
            .ctx
            .sql("select * from memtable")
            .await?
            .collect()
            .await?;
        let _ = arrow::util::pretty::print_batches(&df);

        let df = self
            .ctx
            .sql("SELECT MAX(row_end_indexes) AS max FROM memtable")
            .await?;
        let results = df.collect().await?;

        if let Some(batch) = results.first() {
            let column = batch.column(0);
            let max_value = column
                .as_any()
                .downcast_ref::<UInt64Array>()
                .ok_or_else(|| {
                    DataFusionError::Execution("Failed to downcast to UInt64Array".to_string())
                })?
                .value(0);
            self.total_row_count = (max_value + 1) as i64;
            info!("Total num of rows: {}", self.total_row_count);
        }

        self.distribute_data_files().await?;

        // Start periodic retry task if configured
        self.start_periodic_retry_task().await;

        Ok(())
    }

    pub async fn get_workers_to_connect(&self, start: u64, end: u64) -> Result<Vec<String>> {
        info!("start: {}, end: {}", start, end);
        let df = self.ctx.sql(format!("SELECT worker_ids FROM memtable WHERE row_start_indexes <= {} AND row_end_indexes >= {}", end, start).as_str()).await?;
        let results = df.collect().await?;
        let _ = arrow::util::pretty::print_batches(&results);

        let mut string_results: Vec<String> = Vec::new();

        for batch in results {
            for row in 0..batch.num_rows() {
                let mut row_string = String::new();
                let array = batch.column(0);
                let value = array
                    .as_any()
                    .downcast_ref::<UInt64Array>()
                    .ok_or_else(|| {
                        DataFusionError::Execution("Failed to downcast to UInt64Array".to_string())
                    })?
                    .value(row);
                let url = self.worker_map.get(&value.to_string()).ok_or_else(|| {
                    DataFusionError::Execution(format!("Worker {} not found in worker map", value))
                })?;
                row_string.push_str(url);
                string_results.push(row_string);
            }
        }
        Ok(string_results)
    }

    async fn fetch_data_files(&self) -> Result<()> {
        let memtable = MemTable::load(
            self.data_file_provider.clone(),
            Some(self.num_workers),
            &self.ctx.state(),
        )
        .await
        .map_err(|err: DataFusionError| {
            error!("Error loading table: {}", err);
            err
        })?;
        self.ctx
            .register_table(self.mem_table_name.clone(), Arc::new(memtable))
            .map_err(|err: DataFusionError| {
                error!("Failed to register table: {}", err);
                err
            })?;
        Ok(())
    }

    async fn distribute_data_files(&self) -> Result<()> {
        let table = self
            .ctx
            .table_provider(TableReference::parse_str(&self.mem_table_name))
            .await
            .map_err(|err: DataFusionError| {
                error!("Error retrieving table: {}", err);
                err
            })?;
        let plan = table.scan(&self.ctx.state(), None, &[], None).await?;
        let plan = RepartitionExec::try_new(plan, Partitioning::RoundRobinBatch(self.num_workers))?;
        let plan = DistributedWriterExec::new(
            Arc::new(plan),
            self.worker_map.clone(),
            self.metadata_schema.clone(),
            self.num_workers,
            self.config.clone(),
        );
        let _ = execute_stream(Arc::new(plan), self.ctx.task_ctx())?
            .collect::<Vec<_>>()
            .await;
        Ok(())
    }

    /// Start a background task that periodically retries data distribution to any workers
    /// that may have failed during initial distribution or restarted
    async fn start_periodic_retry_task(&mut self) {
        let retry_interval_seconds: u64 =
            std::env::var("ARROW_CACHE_PERIODIC_RETRY_INTERVAL_SECONDS")
                .unwrap_or_else(|_| "30".to_string()) // Default: retry every 30 seconds
                .parse()
                .unwrap_or(30);

        if retry_interval_seconds == 0 {
            info!("Periodic retry disabled (ARROW_CACHE_PERIODIC_RETRY_INTERVAL_SECONDS=0)");
            return;
        }

        info!(
            "Starting periodic retry task (interval: {}s)",
            retry_interval_seconds
        );

        let ctx = self.ctx.clone();
        let num_workers = self.num_workers;
        let mem_table_name = self.mem_table_name.clone();
        let worker_map = self.worker_map.clone();
        let metadata_schema = self.metadata_schema.clone();
        let config = self.config.clone();

        let handle = tokio::spawn(async move {
            let mut retry_interval = interval(Duration::from_secs(retry_interval_seconds));
            retry_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

            loop {
                retry_interval.tick().await;

                info!("Attempting periodic data redistribution to workers");

                match Self::periodic_distribute_data_files(
                    &ctx,
                    num_workers,
                    &mem_table_name,
                    worker_map.clone(),
                    metadata_schema.clone(),
                    config.clone(),
                )
                .await
                {
                    Ok(_) => {
                        info!("Periodic data redistribution completed successfully");
                    }
                    Err(e) => {
                        warn!("Periodic data redistribution failed: {}", e);
                    }
                }
            }
        });

        self.retry_task_handle = Some(handle);
    }

    /// Periodic version of distribute_data_files that can be called from background task
    async fn periodic_distribute_data_files(
        ctx: &Arc<SessionContext>,
        num_workers: usize,
        mem_table_name: &str,
        worker_map: Arc<HashMap<String, String>>,
        metadata_schema: SchemaRef,
        config: Arc<CacheConfig>,
    ) -> Result<()> {
        let table = ctx
            .table_provider(TableReference::parse_str(mem_table_name))
            .await
            .map_err(|err: DataFusionError| {
                error!("Error retrieving table for periodic retry: {}", err);
                err
            })?;
        let plan = table.scan(&ctx.state(), None, &[], None).await?;
        let plan = RepartitionExec::try_new(plan, Partitioning::RoundRobinBatch(num_workers))?;
        let plan = DistributedWriterExec::new(
            Arc::new(plan),
            worker_map,
            metadata_schema,
            num_workers,
            config,
        );
        let _ = execute_stream(Arc::new(plan), ctx.task_ctx())?
            .collect::<Vec<_>>()
            .await;
        Ok(())
    }
}

/// Cleanup implementation to properly shutdown retry task
impl Drop for Distributor {
    fn drop(&mut self) {
        if let Some(handle) = self.retry_task_handle.take() {
            handle.abort();
        }
    }
}
