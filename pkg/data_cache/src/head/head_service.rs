use crate::head::head::Distributor;
use crate::head::provider::DataFileTableProvider;
use arrow_flight::{
    Action, Criteria, Empty, FlightData, FlightDescriptor, FlightEndpoint, FlightInfo,
    HandshakeRequest, HandshakeResponse, Location, PollInfo, PutResult, SchemaResult, Ticket,
    flight_service_server::{FlightService, FlightServiceServer},
};
use arrow_schema::{DataType, Field, Schema, SchemaRef};
use bincode;
use bytes::Bytes;
use datafusion::prelude::SessionContext;
use futures::Stream;
use std::collections::HashMap;
use std::pin::Pin;
use std::sync::Arc;
use tonic::{Request, Response, Status, Streaming};
use tracing::{info, error};

/// Head node service implementing Apache Arrow Flight protocol for distributed query coordination.
///
/// **IMPORTANT**: This service handles **coordination metadata** only and does NOT
/// deal with actual data schemas. The head node uses a **metadata schema** for
/// worker coordination, while workers separately manage **data schemas** for
/// actual data processing.
///
/// # Dual Schema Architecture - Head Node Coordination
///
/// The distributed caching system uses **two completely separate Arrow schemas**:
///
/// ## 1. **Metadata Schema** (Head Node - This Service):
/// - **Purpose**: Coordinate worker assignments and data distribution
/// - **Created by**: [`metadata_arrow_schema()`] function
/// - **Contains**: `worker_ids`, `row_start_indexes`, `row_end_indexes`, `file_paths`
/// - **Used for**: Flight protocol coordination, worker task distribution
/// - **Location**: Head node only (this service)
///
/// ## 2. **Data Schema** (Worker Nodes):
/// - **Purpose**: Describe actual data structure being cached/queried
/// - **Created by**: Converting Iceberg schema to Arrow in [`WorkerDataSource`]
/// - **Contains**: Actual data columns (e.g., `id`, `user_id`, `event_type`, `timestamp`)
/// - **Used for**: Query execution, data processing, result generation
/// - **Location**: Worker nodes only
///
/// # Schema Separation Benefits
///
/// - **Modularity**: Head nodes don't need to understand data semantics
/// - **Performance**: Lightweight coordination without full data schema overhead
/// - **Evolution**: Data schemas can change independently of coordination logic
/// - **Scalability**: Head node coordination scales independently of data complexity
///
/// # Architecture
///
/// The head service operates as the coordinator in a head-worker distributed system:
/// - Receives flight information requests from clients
/// - Partitions data ranges across available worker nodes using **metadata schema**
/// - Distributes file assignments to worker nodes
/// - Provides flight endpoints for distributed query execution
/// - **Never handles actual data** - only coordination metadata
///
/// # Flight Protocol Usage
///
/// - **`get_flight_info`**: Provides flight information with worker endpoints (uses metadata schema)
/// - Other Flight methods are not currently implemented
///
/// # Coordination Data Flow
///
/// ```text
/// ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
/// │   Client        │───▶│   HeadService   │───▶│   Distributor   │
/// │(get_flight_info)│    │(metadata schema)│    │(metadata schema)│
/// └─────────────────┘    └─────────────────┘    └─────────────────┘
///                                 │                       │
///                                 ▼                       ▼
///                        ┌─────────────────┐    ┌─────────────────┐
///                        │ Flight Endpoints│    │ Worker Nodes    │
///                        │(metadata schema)│    │ (data schemas)  │
///                        └─────────────────┘    └─────────────────┘
/// ```
///
/// # Example Coordination vs Data
///
/// **Head Node Metadata** (coordination only):
/// ```text
/// ┌────────────┬─────────────────┬───────────────┬─────────────────────────┐
/// │ worker_ids │ row_start_index │ row_end_index │ file_paths              │
/// ├────────────┼─────────────────┼───────────────┼─────────────────────────┤
/// │ 0          │ 0               │ 999           │ ["/data/part1.parquet"] │
/// │ 1          │ 1000            │ 1999          │ ["/data/part2.parquet"] │
/// └────────────┴─────────────────┴───────────────┴─────────────────────────┘
/// ```
///
/// **Worker Node Data** (actual data structure):
/// ```text
/// ┌────────┬─────────┬────────────┬─────────────┬─────────────┐
/// │   id   │ user_id │ event_type │ timestamp   │ cache_index │
/// │ Int64  │ String  │   String   │ Timestamp   │   UInt64    │
/// └────────┴─────────┴────────────┴─────────────┴─────────────┘
/// ```
///
/// # Performance Considerations
///
/// - Partitions data to balance load across workers (using metadata schema)
/// - Uses efficient serialization for flight coordination metadata
/// - Maintains worker topology for optimal data distribution
/// - Supports dynamic worker scaling without data schema dependencies
/// - Lightweight coordination operations independent of data complexity
///
/// # See Also
///
/// ## Head Node Coordination (Metadata Schema):
/// - [`Distributor`]: Handles data distribution and worker coordination
/// - [`get_partition_range`]: Calculates data partitioning ranges
/// - [`IndexPair`]: Represents row ranges in flight tickets
/// - [`metadata_arrow_schema()`]: Creates the coordination metadata schema
///
/// ## Worker Node Data Processing (Data Schema):
/// - [`WorkerDataSource`]: Manages data schemas for actual data processing
/// - [`WorkerService`]: Handles data queries using data schemas
pub struct HeadService {
    distributor: Distributor,
}

impl HeadService {
    #[allow(dead_code)]
    pub fn new(distributor: Distributor) -> Self {
        Self { distributor }
    }

    /// Try to get the total row count from the memtable if it exists
    async fn get_total_row_count(&self) -> Result<usize, Box<dyn std::error::Error>> {
        use arrow::array::UInt64Array;
        use datafusion::error::DataFusionError;

        let df = self.distributor.context()
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
            Ok((max_value + 1) as usize)
        } else {
            Err("No rows found in memtable".into())
        }
    }
}

#[tonic::async_trait]
impl FlightService for HeadService {
    type HandshakeStream =
        Pin<Box<dyn Stream<Item = Result<HandshakeResponse, Status>> + Send + 'static>>;
    async fn handshake(
        &self,
        _request: Request<Streaming<HandshakeRequest>>,
    ) -> Result<Response<Self::HandshakeStream>, Status> {
        todo!()
    }
    type ListFlightsStream =
        Pin<Box<dyn Stream<Item = Result<FlightInfo, Status>> + Send + 'static>>;
    async fn list_flights(
        &self,
        _request: Request<Criteria>,
    ) -> Result<Response<Self::ListFlightsStream>, Status> {
        todo!()
    }
    /// Provides flight information for distributed query execution.
    ///
    /// This method handles client requests for flight information by partitioning
    /// data ranges across available worker nodes and returning flight endpoints
    /// that clients can use to query specific data ranges.
    ///
    /// # Parameters
    ///
    /// - `request`: Flight descriptor containing partition information in the path
    ///   - `path[0]`: Local rank (partition ID) for the requesting client
    ///   - `path[1]`: Total number of partitions across all clients
    ///
    /// # Returns
    ///
    /// Returns [`FlightInfo`] containing:
    /// - Flight endpoints with worker URIs for the requested partition
    /// - Serialized [`IndexPair`] tickets containing row ranges
    /// - Schema information for the distributed data
    ///
    /// # Algorithm
    ///
    /// 1. Parse local rank and total partitions from the flight descriptor
    /// 2. Calculate data partition range using [`get_partition_range`]
    /// 3. Get worker nodes responsible for the partition range
    /// 4. Create flight endpoints with worker locations and row range tickets
    /// 5. Return flight information with schema and endpoints
    ///
    /// # Data Partitioning
    ///
    /// Data is partitioned evenly across the requested number of partitions:
    /// - Each partition gets approximately `total_rows / num_partitions` rows
    /// - Partition ranges are calculated to avoid gaps or overlaps
    /// - Empty partitions are handled gracefully
    ///
    /// # Error Handling
    ///
    /// - Returns `Status::invalid_argument` if path parameters are missing
    /// - Returns `Status::invalid_argument` if parameters cannot be parsed
    /// - Returns `Status::internal` if worker lookup fails
    /// - Returns `Status::internal` if serialization fails
    ///
    /// # Example Usage
    ///
    /// For a client requesting partition 0 of 4 total partitions:
    /// ```
    /// path = ["0", "4"]
    /// // Returns flight endpoints for rows 0 to (total_rows/4 - 1)
    /// ```
    ///
    /// # Performance Considerations
    ///
    /// - Uses efficient binary serialization for flight metadata
    /// - Minimizes network communication by providing direct worker endpoints
    /// - Balances load across available workers
    /// - Supports parallel query execution across partitions
    ///
    /// # See Also
    ///
    /// - [`get_partition_range`]: Calculates partition boundaries
    /// - [`Distributor::get_workers_to_connect`]: Finds responsible workers
    /// - [`IndexPair`]: Row range representation in tickets
    async fn get_flight_info(
        &self,
        request: Request<FlightDescriptor>,
    ) -> Result<Response<FlightInfo>, Status> {
        let request = request.into_inner();
        let local_rank = request
            .path
            .first()
            .ok_or_else(|| Status::invalid_argument("Missing local_rank in path"))?;
        let total = request
            .path
            .get(1)
            .ok_or_else(|| Status::invalid_argument("Missing total in path"))?;
        let mut pair = IndexPair { start: 0, end: 0 };
        let total_parsed = total
            .parse()
            .map_err(|_| Status::invalid_argument("Invalid total value"))?;
        let local_rank_parsed = local_rank
            .parse()
            .map_err(|_| Status::invalid_argument("Invalid local_rank value"))?;

        // Get the current total row count (may need to initialize it)
        let total_row_count = if self.distributor.total_row_count == 0 {
            // Try to get row count from memtable if available
            match self.get_total_row_count().await {
                Ok(count) => count,
                Err(_) => {
                    info!("Total row count not yet available, returning empty endpoints");
                    0
                }
            }
        } else {
            self.distributor.total_row_count as usize
        };

        let workers = if let Some((start, end)) = get_partition_range(
            total_row_count,
            total_parsed,
            local_rank_parsed,
        ) {
            //TODO: fetch total count
            pair = IndexPair { start, end };
            self.distributor.get_workers_to_connect(start, end).await
        } else {
            Ok(Vec::new())
        };
        let mut endpoints = vec![];
        for uri in workers.map_err(|e| Status::internal(format!("Error getting workers: {}", e)))? {
            endpoints.push(FlightEndpoint {
                ticket: Some(Ticket::new(Bytes::from(
                    bincode::serialize(&pair)
                        .map_err(|e| Status::internal(format!("Serialization error: {}", e)))?,
                ))),
                location: vec![Location { uri }],
                expiration_time: None,
                app_metadata: Bytes::from(
                    bincode::serialize(&pair)
                        .map_err(|e| Status::internal(format!("Serialization error: {}", e)))?,
                ),
            });
        }

        let flight_info = FlightInfo {
            schema: Bytes::new(),
            flight_descriptor: Some(request),
            endpoint: endpoints,
            total_records: -1,
            total_bytes: -1,
            ordered: false,
            app_metadata: Default::default(),
        };

        let flight_info = flight_info
            .try_with_schema(metadata_arrow_schema().as_ref())
            .map_err(|e| Status::internal(format!("Schema error: {}", e)))?; // TODO:// pass correct schema
        Ok(Response::new(flight_info))
    }
    async fn poll_flight_info(
        &self,
        _request: Request<FlightDescriptor>,
    ) -> Result<Response<PollInfo>, Status> {
        todo!()
    }
    async fn get_schema(
        &self,
        _request: Request<FlightDescriptor>,
    ) -> Result<Response<SchemaResult>, Status> {
        unimplemented!()
    }

    type DoGetStream = Pin<Box<dyn Stream<Item = Result<FlightData, Status>> + Send + 'static>>;

    async fn do_get(
        &self,
        _request: Request<Ticket>,
    ) -> Result<Response<<Self as FlightService>::DoGetStream>, Status> {
        todo!()
    }

    type DoPutStream = Pin<Box<dyn Stream<Item = Result<PutResult, Status>> + Send + 'static>>;

    async fn do_put(
        &self,
        _request: Request<Streaming<FlightData>>,
    ) -> Result<Response<Self::DoPutStream>, Status> {
        todo!()
    }

    type DoExchangeStream =
        Pin<Box<dyn Stream<Item = Result<FlightData, Status>> + Send + 'static>>;

    async fn do_exchange(
        &self,
        _request: Request<Streaming<FlightData>>,
    ) -> Result<Response<Self::DoExchangeStream>, Status> {
        todo!()
    }

    type DoActionStream =
        Pin<Box<dyn Stream<Item = Result<arrow_flight::Result, Status>> + Send + 'static>>;

    async fn do_action(
        &self,
        _request: Request<Action>,
    ) -> Result<Response<Self::DoActionStream>, Status> {
        todo!()
    }

    type ListActionsStream =
        Pin<Box<dyn Stream<Item = Result<arrow_flight::ActionType, Status>> + Send + 'static>>;

    async fn list_actions(
        &self,
        _request: Request<Empty>,
    ) -> Result<Response<Self::ListActionsStream>, Status> {
        todo!()
    }
}

use super::config::config::CacheConfig;
use serde::{Deserialize, Serialize};

/// Represents a row range for distributed query execution.
///
/// This structure is used to communicate row ranges between the head node and
/// worker nodes in the distributed caching system. It is serialized into
/// flight tickets and application metadata for efficient communication.
///
/// # Fields
///
/// - `start`: Starting row index (inclusive)
/// - `end`: Ending row index (inclusive)
///
/// # Serialization
///
/// The struct is serialized using `bincode` for efficient binary representation
/// in flight tickets and metadata. This enables fast serialization/deserialization
/// across network boundaries.
///
/// # Usage
///
/// ```rust
/// let range = IndexPair { start: 0, end: 999 };
/// // Represents rows 0 through 999 (1000 rows total)
/// ```
///
/// # See Also
///
/// - [`get_partition_range`]: Creates partition ranges that are converted to IndexPair
/// - [`get_flight_info`]: Uses IndexPair in flight tickets
/// - [`do_get`]: Deserializes IndexPair from tickets for query execution
#[derive(Serialize, Deserialize, Debug)]
struct IndexPair {
    start: u64,
    end: u64,
}

pub async fn run(
    host: &String,
    port: &String,
    workers: Vec<String>,
) -> datafusion::common::Result<(), Box<dyn std::error::Error>> {
    let ctx = Arc::new(SessionContext::new());
    let addr = format!("{host}:{port}").parse()?;
    let num_workers = workers.len();
    let cache_config = CacheConfig::shared_from_env()
        .map_err(|e| format!("Failed to load dataset config: {}", e))?;
    let metadata_schema = metadata_arrow_schema();
    info!(
        "Creating DataFileTableProvider with schema: {:?}",
        metadata_schema
    );
    let provider = DataFileTableProvider::new(
        &cache_config.dataset.metadata_loc,
        &cache_config.dataset.table_name,
        &cache_config.dataset.schema_name,
        metadata_schema.clone(),
        num_workers,
    )
    .await
    .map_err(|e| format!("Failed to create provider: {}", e))?;
    let mut worker_map: HashMap<String, String> = HashMap::new();
    for (index, worker_uri) in workers.into_iter().enumerate() {
        // Strip http:// prefix if present before adding grpc:// prefix
        let clean_uri = worker_uri.strip_prefix("http://").unwrap_or(&worker_uri);
        worker_map.insert(index.to_string(), format!("grpc://{clean_uri}"));
    }
    let provider_arc = Arc::new(provider);
    let worker_map_arc = Arc::new(worker_map);

    let mut distributor = Distributor::new(
        ctx.clone(),
        num_workers,
        provider_arc.clone(),
        "memtable".to_string(),
        worker_map_arc.clone(),
        metadata_schema.clone(),
        cache_config.clone(),
    );

    // Only do minimal initialization (fetch data files) without distributing
    info!("🚀 Starting minimal initialization (gRPC server will start immediately)");
    let _ = distributor.fetch_data_files().await;
    info!("✅ Minimal initialization completed, starting gRPC server");

    // Start background distribution task
    tokio::spawn(async move {
        info!("🚀 Starting background data distribution");

        // Add delay to allow gRPC server to start and workers to be ready
        tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;

        match distributor.distribute_and_setup().await {
            Ok(_) => {
                info!("✅ Background data distribution completed successfully");
            }
            Err(e) => {
                error!("❌ Background data distribution failed: {}", e);
                // Continue running even if distribution fails - periodic retries will handle it
            }
        }
    });

    info!("🌐 Starting gRPC server on {} (data distribution will happen in background)", addr);
    let mut service_distributor = Distributor::new(
        ctx,
        num_workers,
        provider_arc,
        "memtable".to_string(),
        worker_map_arc,
        metadata_schema,
        cache_config,
    );

    // Initialize the service distributor's memtable so it can handle flight info requests
    let _ = service_distributor.fetch_data_files().await;

    let service = HeadService { distributor: service_distributor };
    tonic::transport::Server::builder()
        .add_service(FlightServiceServer::new(service))
        .serve(addr)
        .await
        .map_err(|e| format!("Error starting server: {}", e))?;
    Ok(())
}

/// Creates the Arrow schema for **coordination metadata** in the distributed caching system.
///
/// **IMPORTANT**: This function creates the **metadata schema** used for coordination
/// between the head node and worker nodes. This is **NOT** the data schema that describes
/// the actual data being processed. The data schema is handled separately by worker nodes
/// and is converted from Iceberg format to Arrow format in [`WorkerDataSource`].
///
/// # Dual Schema Architecture
///
/// The distributed caching system uses **two distinct Arrow schemas**:
///
/// 1. **Metadata Schema** (this function):
///    - Used by head node for worker coordination
///    - Contains worker assignments and file distribution information
///    - Transmitted via Arrow Flight for system coordination
///
/// 2. **Data Schema** (in workers):
///    - Describes the structure of actual data being cached/queried
///    - Converted from Iceberg table metadata to Arrow format
///    - Enhanced with `cache_index` column for efficient indexing
///    - See [`WorkerDataSource::table_schema`] and [`WorkerDataSource::output_schema`]
///
/// # Metadata Schema Fields
///
/// The coordination metadata schema contains four essential fields:
///
/// - **`worker_ids`** (`UInt64`, non-nullable): Unique identifiers for worker nodes
///   responsible for processing specific data ranges. Used for routing queries
///   to the appropriate workers.
///
/// - **`row_start_indexes`** (`UInt64`, non-nullable): Starting row indices for
///   data ranges assigned to each worker. Defines the beginning of each worker's
///   data partition (inclusive).
///
/// - **`row_end_indexes`** (`UInt64`, non-nullable): Ending row indices for
///   data ranges assigned to each worker. Defines the end of each worker's
///   data partition (inclusive).
///
/// - **`file_paths`** (`List<Utf8View>`, non-nullable): List of file paths
///   that each worker is responsible for processing. Supports multiple files
///   per worker for efficient data distribution.
///
/// # Returns
///
/// Returns an [`SchemaRef`] (reference-counted Arrow schema) that can be:
/// - Used in flight information responses for coordination
/// - Shared across multiple head node components without cloning
/// - Passed to DataFusion table providers for metadata operations
/// - Serialized in Apache Arrow Flight protocol messages
///
/// # Usage in Distributed System
///
/// This **metadata schema** is used throughout the head node coordination layer:
/// 1. **Flight Information**: Attached to flight responses for schema validation
/// 2. **Worker Communication**: Defines the structure of coordination exchanges
/// 3. **Query Planning**: Used by DataFusion for distribution planning
/// 4. **Data Distribution**: Describes how data is partitioned across workers
///
/// # Example Coordination Metadata Structure
///
/// ```text
/// ┌────────────┬─────────────────┬───────────────┬─────────────────────────┐
/// │ worker_ids │ row_start_index │ row_end_index │ file_paths              │
/// ├────────────┼─────────────────┼───────────────┼─────────────────────────┤
/// │ 0          │ 0               │ 999           │ ["/data/part1.parquet"] │
/// │ 1          │ 1000            │ 1999          │ ["/data/part2.parquet"] │
/// │ 2          │ 2000            │ 2999          │ ["/data/part3.parquet"] │
/// └────────────┴─────────────────┴───────────────┴─────────────────────────┘
/// ```
///
/// # Schema Separation Rationale
///
/// **Why separate metadata and data schemas?**
/// - **Separation of Concerns**: Coordination logic is independent of data structure
/// - **Schema Evolution**: Data schema can evolve without affecting coordination
/// - **Performance**: Lightweight metadata operations don't need full data schema
/// - **Modularity**: Head nodes don't need to understand data semantics
///
/// # Schema Compatibility
///
/// - Uses `UInt64` for row indices to support large datasets (up to 2^64 rows)
/// - Uses `Utf8View` for efficient string storage and reduced memory footprint
/// - Non-nullable fields ensure data integrity across the distributed system
/// - List type supports variable numbers of files per worker
///
/// # Performance Considerations
///
/// - Schema is created once and reused via `Arc<Schema>` for efficiency
/// - `Utf8View` provides zero-copy string operations for file paths
/// - Minimal schema overhead for coordination communication
/// - Compatible with Arrow's columnar format for fast serialization
///
/// # See Also
///
/// ## Metadata Schema Usage:
/// - [`DataFileTableProvider`]: Uses this schema for coordination table registration
/// - [`get_flight_info`]: Attaches this schema to flight responses
/// - [`Distributor`]: Uses this schema for metadata operations
///
/// ## Data Schema Usage (Worker Side):
/// - [`WorkerDataSource::table_schema`]: Original data schema from Iceberg → Arrow
/// - [`WorkerDataSource::output_schema`]: Data schema + cache_index column
/// - [`iceberg::arrow::schema_to_arrow_schema`]: Converts Iceberg schema to Arrow
fn metadata_arrow_schema() -> SchemaRef {
    let columns = vec![
        Field::new("worker_ids", DataType::UInt64, false),
        Field::new("row_start_indexes", DataType::UInt64, false),
        Field::new("row_end_indexes", DataType::UInt64, false),
        Field::new(
            "file_paths",
            DataType::List(Arc::new(Field::new("item", DataType::Utf8View, true))),
            false,
        ),
    ];
    Arc::new(Schema::new(columns))
}

/// Calculates the row range for a specific partition in distributed query execution.
///
/// This function divides the total data count evenly across the requested number
/// of partitions and returns the start and end row indices for the specified
/// partition. It handles edge cases like empty datasets and ensures no gaps
/// or overlaps between partitions.
///
/// # Parameters
///
/// - `total_count`: Total number of rows in the dataset
/// - `num_partitions`: Number of partitions to divide the data into
/// - `partition_id`: Zero-based ID of the partition to calculate range for
///
/// # Returns
///
/// Returns `Some((start, end))` where:
/// - `start`: First row index for this partition (inclusive)
/// - `end`: Last row index for this partition (inclusive)
///
/// Returns `None` if:
/// - `total_count` is 0 (empty dataset)
/// - `num_partitions` is 0 (invalid partition count)
/// - `partition_id` >= `num_partitions` (invalid partition ID)
///
/// # Algorithm
///
/// 1. Calculate rows per partition using ceiling division
/// 2. Compute start index as `partition_id * rows_per_partition`
/// 3. Compute end index as `min(start + rows_per_partition, total_count)`
/// 4. Return inclusive range `[start, end-1]`
///
/// # Examples
///
/// ```rust
/// // 100 rows, 4 partitions
/// assert_eq!(get_partition_range(100, 4, 0), Some((0, 24)));   // Rows 0-24
/// assert_eq!(get_partition_range(100, 4, 1), Some((25, 49)));  // Rows 25-49
/// assert_eq!(get_partition_range(100, 4, 2), Some((50, 74)));  // Rows 50-74
/// assert_eq!(get_partition_range(100, 4, 3), Some((75, 99)));  // Rows 75-99
///
/// // Edge cases
/// assert_eq!(get_partition_range(0, 4, 0), None);     // Empty dataset
/// assert_eq!(get_partition_range(100, 4, 4), None);   // Invalid partition ID
/// ```
///
/// # Performance Considerations
///
/// - Uses ceiling division to handle uneven partition sizes
/// - Ensures the last partition gets any remaining rows
/// - Constant time complexity O(1)
/// - No memory allocation required
fn get_partition_range(
    total_count: usize,
    num_partitions: usize,
    partition_id: usize,
) -> Option<(u64, u64)> {
    if total_count == 0 || num_partitions == 0 || partition_id >= num_partitions {
        return None;
    }

    let ids_per_partition = total_count.div_ceil(num_partitions);

    let start_index = partition_id * ids_per_partition;
    let end_index = (start_index + ids_per_partition).min(total_count);

    if start_index >= total_count {
        None
    } else {
        Some((start_index as u64, (end_index - 1) as u64))
    }
}
