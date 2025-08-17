use std::env;
use std::fs;
use std::time::Duration;
use tokio::time::sleep;
use tracing::{info, warn, error, debug};
use tracing_subscriber;
use trust_dns_resolver::TokioAsyncResolver;
use trust_dns_resolver::config::*;
use serde::{Deserialize, Serialize};
use serde_json;

#[path = "../mod.rs"]
mod head;

/// Worker configuration structure for parsing worker-mapping.json
#[derive(Debug, Clone, Serialize, Deserialize)]
struct WorkerConfig {
    host: String,
    port: u16,
}

/// Root structure for worker-mapping.json
#[derive(Debug, Clone, Serialize, Deserialize)]
struct WorkerMapping {
    workers: Vec<WorkerConfig>,
}

/// Load worker configuration from /etc/arrow-cache/worker-mapping.json if it exists
/// Returns None if file doesn't exist or can't be parsed
fn load_worker_config() -> Option<Vec<String>> {
    let config_path = "/etc/arrow-cache/worker-mapping.json";

    info!("🔍 Checking for worker config file at: {}", config_path);

    match fs::read_to_string(config_path) {
        Ok(content) => {
            info!("✅ Successfully read worker config file");
            debug!("📄 Worker config file content: {}", content);

            match serde_json::from_str::<WorkerMapping>(&content) {
                Ok(mapping) => {
                    let workers: Vec<String> = mapping.workers
                        .into_iter()
                        .map(|w| format!("http://{}:{}", w.host, w.port))
                        .collect();

                    info!("🎯 Loaded {} workers from config file: {:?}", workers.len(), workers);
                    Some(workers)
                }
                Err(e) => {
                    error!("❌ Failed to parse worker config JSON: {}", e);
                    warn!("📝 Config file content was: {}", content);
                    None
                }
            }
        }
        Err(e) => {
            info!("ℹ️  Worker config file not found or not readable: {}", e);
            info!("🔄 Will fall back to environment variable construction");
            None
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt().init();

    let args: Vec<String> = std::env::args().collect();
    info!("🚀 Arguments passed to head: {:?}", &args[1..]);

    // Print all relevant environment variables for debugging
    info!("🔍 Environment Variables:");
    if let Ok(runtime_env) = env::var("RUNTIME_ENV") {
        info!("  RUNTIME_ENV = {}", runtime_env);
    } else {
        info!("  RUNTIME_ENV = <not set>");
    }

    if let Ok(lws_leader) = env::var("LWS_LEADER_ADDRESS") {
        info!("  LWS_LEADER_ADDRESS = {}", lws_leader);
    }

    if let Ok(lws_size) = env::var("LWS_GROUP_SIZE") {
        info!("  LWS_GROUP_SIZE = {}", lws_size);
    }

    if let Ok(worker_service) = env::var("WORKER_SERVICE_NAME") {
        info!("  WORKER_SERVICE_NAME = {}", worker_service);
    }

    let mut rpc_hosts = Vec::new();

    // First, try to load worker configuration from config file
    if let Some(config_workers) = load_worker_config() {
        info!("✅ Using worker configuration from config file");
        rpc_hosts = config_workers;
    } else if env::var("RUNTIME_ENV").is_ok() {
        info!("🏠 Using localhost configuration (RUNTIME_ENV is set)");
        rpc_hosts.push(format!("{}:{}", "localhost", "50052"));
        rpc_hosts.push(format!("{}:{}", "localhost", "50053"));
    } else {
        info!("🔧 Using LWS environment variable construction");

        let lws_leader_address = env::var("LWS_LEADER_ADDRESS")?;
        let lws_size: i32 = env::var("LWS_GROUP_SIZE")?.parse()?;
        let rpc_port = 50051;

        info!("🎯 LWS Configuration:");
        info!("  Leader Address: {}", lws_leader_address);
        info!("  Group Size: {}", lws_size);
        info!("  RPC Port: {}", rpc_port);

        let service_tokens: Vec<&str> = lws_leader_address.split('.').collect();
        info!("  Service Tokens: {:?}", service_tokens);

        let _resolver =
            TokioAsyncResolver::tokio(ResolverConfig::default(), ResolverOpts::default());

        for i in 1..lws_size {
            let host = format!(
                "{}-{}.{}",
                service_tokens[0],
                i,
                service_tokens[1..].join(".")
            );

            info!("🔗 Constructing worker host {}: {}", i, host);

            sleep(Duration::from_secs(10)).await;

            let worker_url = format!("http://{}:{}", host, rpc_port);
            info!("➕ Adding worker: {}", worker_url);
            rpc_hosts.push(worker_url);
        }
    }

    info!("🎯 Final RPC Hosts: {:?}", rpc_hosts);
    let host = args.get(1).ok_or("Missing host argument")?;
    let port = args.get(2).ok_or("Missing port argument")?;

    info!("🌐 Starting head service on {}:{}", host, port);
    head::head_service::run(host, port, rpc_hosts).await
}
