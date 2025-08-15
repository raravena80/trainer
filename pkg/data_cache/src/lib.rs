//! Distributed Arrow-based data caching system with dual schema architecture.
//!
//! # Dual Schema Architecture
//!
//! This caching system uses **two completely separate Arrow schemas** for different purposes:
//!
//! ## 1. Metadata Schema (Head Node Coordination)
//! - **Purpose**: Coordinate worker assignments and data distribution
//! - **Location**: Head node ([`head`] module)
//! - **Created by**: [`head::head_service::metadata_arrow_schema()`]
//! - **Contains**: `worker_ids`, `row_start_indexes`, `row_end_indexes`, `file_paths`
//! - **Format**: Arrow schema with coordination fields
//! - **Usage**: Flight protocol, task distribution, worker routing
//!
//! ## 2. Data Schema (Worker Data Processing)
//! - **Purpose**: Describe actual data structure being cached and queried
//! - **Location**: Worker nodes ([`worker`] module)
//! - **Created by**: Converting Iceberg schema to Arrow in [`worker::worker_datasource::WorkerDataSource`]
//! - **Contains**: Actual data columns (e.g., `id`, `user_id`, `event_type`, `timestamp`) + `cache_index`
//! - **Format**: Arrow schema converted from Iceberg table metadata
//! - **Usage**: Query execution, data processing, result generation
//!
//! # Architecture Benefits
//!
//! - **Separation of Concerns**: Coordination logic independent of data structure
//! - **Schema Evolution**: Data schemas can evolve without affecting coordination
//! - **Performance**: Lightweight metadata operations without full data schema overhead
//! - **Modularity**: Head nodes don't need to understand data semantics
//! - **Scalability**: Coordination scales independently of data complexity
//!
//! # Module Organization
//!
//! - [`config`]: Configuration management for Iceberg table coordinates
//! - [`head`]: Head node coordination using metadata schema
//! - [`worker`]: Worker node data processing using data schema

pub mod config;
pub mod head;
pub mod worker;
