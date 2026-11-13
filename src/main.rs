//SPDX-License-Identifier: MIT

#[global_allocator]
static GLOBAL: Jemalloc = Jemalloc;

mod blockfile;

#[cfg(feature = "esplora")]
mod esplora;
mod forest_journal;
mod header_index;

mod node;

mod parallel_forest;
mod position_timing;
mod prover;

mod block_index;
mod chaininterface;
mod chainview;
mod cli;
mod udata;

use std::env;

use anyhow::Result;
use bitcoincore_rpc::Auth;
use bitcoincore_rpc::Client;
use chaininterface::Blockchain;
use dotenv::dotenv;
use jemallocator::Jemalloc;
use log::info;
use simplelog::Config;
use simplelog::SharedLogger;

pub mod bitcoin_bridge;
use crate::bitcoin_bridge::run_bridge;

fn main() -> anyhow::Result<()> {
    dotenv().ok();

    run_bridge()
}

/// Reads an environment variable, treating unset, empty, or whitespace-only
/// values as absent.
///
/// `.env.sample` lists every variable with an empty value. Copying it to `.env`
/// must fall back to the defaults instead of using empty strings as paths,
/// URLs, ports, or credentials.
fn env_var(name: &str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.trim().is_empty())
}

fn subdir(path: &str) -> String {
    let dir = env_var("DATA_DIR").unwrap_or_else(|| {
        let dir = env::var("HOME").expect("No $HOME env var?");
        dir + "/.bridge"
    });
    dir + "/" + path
}

fn init_logger(log_file: Option<&str>, log_to_term: bool) -> anyhow::Result<()> {
    let mut loggers: Vec<Box<dyn SharedLogger>> = Vec::new();
    if let Some(path) = log_file {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        loggers.push(simplelog::WriteLogger::new(
            log::LevelFilter::Debug,
            Config::default(),
            file,
        ));
    }
    if log_to_term {
        loggers.push(simplelog::TermLogger::new(
            log::LevelFilter::Debug,
            Config::default(),
            simplelog::TerminalMode::Mixed,
            simplelog::ColorChoice::Auto,
        ));
    }
    if !loggers.is_empty() {
        simplelog::CombinedLogger::init(loggers)?;
    }
    Ok(())
}

fn get_chain_provider() -> Result<Box<dyn Blockchain>> {
    #[cfg(feature = "esplora")]
    if let Some(esplora_url) = env_var("ESPLORA_URL") {
        return Ok(Box::new(esplora::EsploraBlockchain::new(esplora_url)));
    }
    let rpc_url = env_var("BITCOIN_CORE_RPC_URL").unwrap_or_else(|| "localhost:8332".into());
    // try to use username and password auth first
    if let Some(username) = env_var("BITCOIN_CORE_RPC_USER") {
        let password = env_var("BITCOIN_CORE_RPC_PASSWORD").ok_or_else(|| {
            anyhow::anyhow!("BITCOIN_CORE_RPC_PASSWORD must be set if BITCOIN_CORE_RPC_USER is set")
        })?;
        info!(
            "Using bitcoin core at {} with username {}",
            rpc_url, username
        );
        let client = Client::new(&rpc_url, Auth::UserPass(username, password));
        match client {
            Ok(client) => {
                return Ok(Box::new(client));
            }
            Err(e) => return Err(anyhow::anyhow!("Couldn't connect to bitcoin core: {e}")),
        }
    }
    // fallback to cookie auth. This is the default for core, but discouraged for security reasons
    let cookie = env_var("BITCOIN_CORE_COOKIE_FILE").unwrap_or_else(|| {
        env::var("HOME")
            .map(|home| format!("{}/.bitcoin/.cookie", home))
            .expect("Failed to find $HOME")
    });
    info!("Using cookie file at {}", cookie);
    let client = Client::new(&rpc_url, Auth::CookieFile(cookie.clone().into()));
    match client {
        Ok(client) => {
            info!("Using bitcoin core at {}", rpc_url);
            Ok(Box::new(client))
        }
        Err(e) => Err(anyhow::anyhow!("Couldn't connect to bitcoin core: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Each test uses its own variable name because tests run in parallel and
    // share the process environment.

    #[test]
    fn env_var_returns_set_values() {
        env::set_var("CASTOR_TEST_ENV_SET", "8433");
        assert_eq!(env_var("CASTOR_TEST_ENV_SET").as_deref(), Some("8433"));
    }

    #[test]
    fn env_var_keeps_surrounding_whitespace_of_set_values() {
        env::set_var("CASTOR_TEST_ENV_PADDED", " secret ");
        assert_eq!(
            env_var("CASTOR_TEST_ENV_PADDED").as_deref(),
            Some(" secret ")
        );
    }

    #[test]
    fn env_var_treats_empty_as_unset() {
        env::set_var("CASTOR_TEST_ENV_EMPTY", "");
        assert_eq!(env_var("CASTOR_TEST_ENV_EMPTY"), None);
    }

    #[test]
    fn env_var_treats_whitespace_as_unset() {
        env::set_var("CASTOR_TEST_ENV_BLANK", "  \t");
        assert_eq!(env_var("CASTOR_TEST_ENV_BLANK"), None);
    }

    #[test]
    fn env_var_treats_missing_as_unset() {
        env::remove_var("CASTOR_TEST_ENV_MISSING");
        assert_eq!(env_var("CASTOR_TEST_ENV_MISSING"), None);
    }
}
