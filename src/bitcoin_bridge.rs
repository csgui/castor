use std::fs;
use std::fs::File;
use std::io;
use std::io::BufReader;
use std::net::SocketAddr;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use anyhow::Context;
use bitcoin::consensus::serialize;
use bitcoin::constants::genesis_block;
use bridge::prefixed_hints::BridgeHints;
use clap::Parser;
use log::info;

use crate::block_index::BlocksIndex;
use crate::blockfile::ProofFile;
use crate::chaininterface::Blockchain;
use crate::chainview;
use crate::cli::CliArgs;
use crate::env_var;
use crate::get_chain_provider;
use crate::header_index::HeaderIndex;
use crate::init_logger;
use crate::node;
use crate::node::ProofBackend;
use crate::node::WorkerContext;
use crate::parallel_forest::build_parallel_forest;
use crate::parallel_forest::KernelBlockSource;
use crate::parallel_forest::ParallelForestConfig;
use crate::prover::FlatFileProver;
use crate::subdir;

pub fn run_bridge() -> anyhow::Result<()> {
    let cli_options = CliArgs::parse();
    fs::DirBuilder::new().recursive(true).create(subdir(""))?;

    init_logger(Some(&subdir("debug.log")), true)?;

    if let Some(hints_path) = cli_options.build_forest.as_deref() {
        let file = File::open(hints_path)?;
        let hints = BridgeHints::from_reader(&mut BufReader::new(file))?;
        let forest_path = cli_options
            .forest_file
            .clone()
            .unwrap_or_else(|| subdir("forest.dat").into());
        let mut config = ParallelForestConfig::new(forest_path);
        config.leaf_map_path = cli_options
            .leaf_map_path
            .clone()
            .unwrap_or_else(|| subdir("leaf-map").into());
        config.header_file_path = cli_options
            .header_file
            .clone()
            .unwrap_or_else(|| subdir("headers.dat").into());
        config.header_index_path = cli_options
            .header_index_path
            .clone()
            .unwrap_or_else(|| subdir("header-index").into());
        if let Some(workers) = cli_options.forest_leaf_workers {
            config.leaf_workers = workers;
        }
        if let Some(workers) = cli_options.forest_chaser_workers {
            config.chaser_workers = workers;
        }
        if let Some(iterations) = cli_options.forest_spin_iterations {
            config.spin_iterations = iterations;
        }
        config.minimum_leaf_capacity = cli_options.forest_leaf_capacity;
        config.lock_pages = !cli_options.forest_no_mlock;

        let bitcoin_datadir = cli_options
            .bitcoin_datadir
            .clone()
            .or_else(|| env_var("BITCOIN_CORE_DATADIR").map(Into::into));
        let source = KernelBlockSource::open(cli_options.network, bitcoin_datadir.as_deref())?;
        let summary = build_parallel_forest(&source, &hints, config)?;
        info!(
            "Built flat forest: leaves={} nodes={} leaf_map_entries={} bytes={} roots={} pages_locked={}",
            summary.leaves,
            summary.initialized_nodes,
            summary.leaf_map_entries,
            summary.file_bytes,
            summary.roots.len(),
            summary.pages_locked
        );
        return Ok(());
    }

    if let Some(hints_path) = cli_options.steady_state.as_deref() {
        let file = File::open(hints_path)?;
        let hints = BridgeHints::from_reader(&mut BufReader::new(file))?;
        let forest_path = cli_options
            .forest_file
            .clone()
            .unwrap_or_else(|| subdir("forest.dat").into());
        let leaf_map_path = cli_options
            .leaf_map_path
            .clone()
            .unwrap_or_else(|| subdir("leaf-map").into());
        let header_file_path = cli_options
            .header_file
            .clone()
            .unwrap_or_else(|| subdir("headers.dat").into());
        let header_index_path = cli_options
            .header_index_path
            .clone()
            .unwrap_or_else(|| subdir("header-index").into());
        let (proof_index, proof_file, view, header_index) =
            std::thread::scope(|scope| -> anyhow::Result<_> {
                let storage = std::thread::Builder::new()
                    .name("bridge-storage-open".to_string())
                    .spawn_scoped(scope, || -> anyhow::Result<_> {
                        Ok((
                            Arc::new(open_index(subdir("proof-index/"))?),
                            Arc::new(ProofFile::new(subdir("proofs").into())?),
                            open_chain_view(cli_options.network)?,
                            Arc::new(HeaderIndex::open(&header_file_path, &header_index_path)?),
                        ))
                    })?;
                storage
                    .join()
                    .map_err(|_| anyhow::anyhow!("storage initialization worker panicked"))?
            })?;
        let (block_notifier_tx, block_notifier_rx) = std::sync::mpsc::channel();
        let client: Arc<dyn Blockchain> = get_chain_provider()?.into();
        let shutdown = Arc::new(AtomicBool::new(false));
        let shutdown_signal = Arc::clone(&shutdown);
        ctrlc::set_handler(move || {
            shutdown_signal.store(true, Ordering::Release);
        })?;
        let pollard_memory_limit = cli_options
            .pollard_memory_mib
            .checked_mul(1024 * 1024)
            .context("Pollard memory limit exceeds usize")?;
        let mut prover = FlatFileProver::new(
            client.clone(),
            header_index.clone(),
            &forest_path,
            subdir("forest.journal").into(),
            &leaf_map_path,
            proof_file.clone(),
            proof_index.clone(),
            hints.stop_height(),
            !cli_options.forest_no_mlock,
            pollard_memory_limit,
            shutdown,
            block_notifier_tx,
        )?;
        start_p2p(
            cli_options.network,
            view.clone(),
            proof_index,
            ProofBackend::CompactProofs(proof_file),
            Some(client),
            Some(header_index),
            block_notifier_rx,
        )?;
        return prover.keep_up();
    }

    anyhow::bail!("either --build-forest or --steady-state is required")
}

fn open_chain_view(network: bitcoin::Network) -> anyhow::Result<Arc<chainview::ChainView>> {
    let store = kv::Store::new(kv::Config {
        path: subdir("chain_view").into(),
        temporary: false,
        use_compression: false,
        flush_every_ms: None,
        cache_capacity: None,
        segment_size: None,
    })?;
    let view = Arc::new(chainview::ChainView::new(store));
    let genesis = genesis_block(network);
    if view.get_height(genesis.block_hash())? != Some(0) {
        view.save_header(genesis.block_hash(), serialize(&genesis.header))?;
        view.save_height(genesis.header.block_hash(), 0)?;
    }
    Ok(view)
}

#[allow(clippy::too_many_arguments)]
fn start_p2p(
    network: bitcoin::Network,
    view: Arc<chainview::ChainView>,
    proof_index: Arc<BlocksIndex>,
    proof_backend: ProofBackend,
    header_source: Option<Arc<dyn Blockchain>>,
    header_index: Option<Arc<HeaderIndex>>,
    block_notifier: std::sync::mpsc::Receiver<bitcoin::BlockHash>,
) -> anyhow::Result<()> {
    info!("Starting P2PV2-only BIP 183 proof server");
    let p2p_host = env_var("P2P_HOST").unwrap_or_else(|| "0.0.0.0".into());
    let p2p_port = env_var("P2P_PORT").unwrap_or_else(|| "8333".into());
    let p2p_listen = format!("{p2p_host}:{p2p_port}");
    let p2p_address: SocketAddr = p2p_listen.parse().with_context(|| {
        format!("invalid P2P listen address {p2p_listen:?}; check P2P_HOST and P2P_PORT")
    })?;
    let worker_context = WorkerContext {
        chainview: view,
        magic: network.magic(),
        proof_index,
        proof_backend,
        header_index,
        header_source,
    };
    node::Node::run(p2p_address, worker_context, block_notifier)
        .map_err(|error| p2p_start_error(p2p_address, error))
}

/// Adds the listen address, and a hint for the common port clash with
/// Bitcoin Core, to P2P startup errors.
fn p2p_start_error(address: SocketAddr, error: node::NodeError) -> anyhow::Error {
    let message = match &error {
        node::NodeError::Bind(bind_error) if bind_error.kind() == io::ErrorKind::AddrInUse => {
            format!(
                "cannot listen for P2P connections on {address}: the port is already in use. \
                 Bitcoin Core listens on port 8333 by default; set P2P_PORT to a free port"
            )
        }
        node::NodeError::Bind(_) => {
            format!("cannot listen for P2P connections on {address}; check P2P_HOST and P2P_PORT")
        }
        _ => format!("cannot start the P2P server on {address}"),
    };
    anyhow::Error::new(error).context(message)
}

fn open_index(path: String) -> anyhow::Result<BlocksIndex> {
    Ok(BlocksIndex {
        database: kv::Store::new(kv::Config {
            path: path.into(),
            temporary: false,
            use_compression: false,
            flush_every_ms: Some(1000),
            cache_capacity: Some(1_000_000),
            segment_size: None,
        })?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn address() -> SocketAddr {
        "0.0.0.0:8333".parse().unwrap()
    }

    #[test]
    fn address_in_use_suggests_p2p_port() {
        let error = node::NodeError::Bind(io::Error::from(io::ErrorKind::AddrInUse));
        let message = p2p_start_error(address(), error).to_string();
        assert!(message.contains("0.0.0.0:8333"), "{message}");
        assert!(message.contains("already in use"), "{message}");
        assert!(message.contains("P2P_PORT"), "{message}");
    }

    #[test]
    fn other_bind_errors_name_the_address() {
        let error = node::NodeError::Bind(io::Error::from(io::ErrorKind::PermissionDenied));
        let error = p2p_start_error(address(), error);
        let message = error.to_string();
        assert!(message.contains("0.0.0.0:8333"), "{message}");
        assert!(!message.contains("already in use"), "{message}");
        assert!(format!("{error:#}").contains("failed to bind P2P listener"));
    }

    #[test]
    fn non_bind_errors_keep_the_source() {
        let error = node::NodeError::Spawn(io::Error::other("no threads"));
        let error = p2p_start_error(address(), error);
        assert!(error.to_string().contains("0.0.0.0:8333"));
        assert!(format!("{error:#}").contains("failed to spawn P2P thread"));
    }
}
