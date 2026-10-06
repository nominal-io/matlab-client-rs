//! Asset and run calls the `nominal` crate does not wrap.
//!
//! Detaching a data source, renaming a reference name, finding the assets that
//! hold a dataset, and changing which assets a run belongs to all exist in the
//! API but not in the crate. Like `event.rs`, this talks to `nominal-api`
//! directly through the re-exports in `nominal-streaming`, and caches one
//! service client per base URL.
//!
//! Callers re-fetch through the crate afterwards, so the handles they hand out
//! hold the same types as everywhere else.

use crate::client::ClientEntry;
use crate::error::{fail, ErrorCode, ErrorHandle};
use crate::runtime::RUNTIME;

use nominal_streaming::api::clients::scout::assets::AsyncAssetServiceClient;
use nominal_streaming::api::clients::scout::AsyncRunServiceClient;
use nominal_streaming::client::conjure::http::client::{AsyncService, ConjureRuntime};
use nominal_streaming::client::conjure::object::ResourceIdentifier;
use nominal_streaming::client::conjure::runtime::{Agent, Client, UserAgent};
use nominal_streaming::prelude::BearerToken;

use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::Arc;

static ASSET_SERVICES: Lazy<Mutex<HashMap<String, AsyncAssetServiceClient<Client>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static RUN_SERVICES: Lazy<Mutex<HashMap<String, AsyncRunServiceClient<Client>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Drop cached service clients. Used by shutdown.
pub(crate) fn clear_scout_services() {
    ASSET_SERVICES.lock().clear();
    RUN_SERVICES.lock().clear();
}

fn conjure_client(base_url: &str, error_out: *mut ErrorHandle) -> Result<Client, ErrorCode> {
    let uri = base_url.try_into().map_err(|e| {
        fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!("invalid base URL {base_url:?}: {e:?}"),
        )
    })?;

    // Building the client sets up hyper resources, which panic without an
    // ambient runtime.
    RUNTIME
        .in_context(|| {
            Client::builder()
                .service("nominal-ffi-scout")
                .user_agent(UserAgent::new(Agent::new(
                    "nominal-ffi",
                    env!("CARGO_PKG_VERSION"),
                )))
                .uri(uri)
                .build()
        })
        .map_err(|e| {
            fail(
                error_out,
                ErrorCode::NominalError,
                format!("could not build API client: {e:?}"),
            )
        })
}

pub(crate) fn asset_service(
    client: &ClientEntry,
    error_out: *mut ErrorHandle,
) -> Result<AsyncAssetServiceClient<Client>, ErrorCode> {
    let base_url = client.base_url();
    if let Some(existing) = ASSET_SERVICES.lock().get(base_url) {
        return Ok(existing.clone());
    }
    let service = AsyncAssetServiceClient::new(
        conjure_client(base_url, error_out)?,
        &Arc::new(ConjureRuntime::default()),
    );
    ASSET_SERVICES
        .lock()
        .insert(base_url.to_owned(), service.clone());
    Ok(service)
}

pub(crate) fn run_service(
    client: &ClientEntry,
    error_out: *mut ErrorHandle,
) -> Result<AsyncRunServiceClient<Client>, ErrorCode> {
    let base_url = client.base_url();
    if let Some(existing) = RUN_SERVICES.lock().get(base_url) {
        return Ok(existing.clone());
    }
    let service = AsyncRunServiceClient::new(
        conjure_client(base_url, error_out)?,
        &Arc::new(ConjureRuntime::default()),
    );
    RUN_SERVICES
        .lock()
        .insert(base_url.to_owned(), service.clone());
    Ok(service)
}

pub(crate) fn bearer(
    client: &ClientEntry,
    error_out: *mut ErrorHandle,
) -> Result<BearerToken, ErrorCode> {
    BearerToken::new(client.token()).map_err(|e| {
        fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!("invalid bearer token: {e}"),
        )
    })
}

pub(crate) fn parse_rid(
    rid: &str,
    what: &str,
    error_out: *mut ErrorHandle,
) -> Result<ResourceIdentifier, ErrorCode> {
    ResourceIdentifier::new(rid).map_err(|e| {
        fail(
            error_out,
            ErrorCode::InvalidParameter,
            format!("{what} is not a valid RID ({rid:?}): {e}"),
        )
    })
}

/// Map a conjure error to ours. Conjure's error implements Debug, not Display.
pub(crate) fn api_error(error_out: *mut ErrorHandle, e: impl std::fmt::Debug) -> ErrorCode {
    fail(error_out, ErrorCode::NominalError, format!("{e:?}"))
}
