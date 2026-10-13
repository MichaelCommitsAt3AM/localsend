//! Text clipboard state machine and authenticated transports.
//!
//! This module never reads an OS clipboard, persists content, or uses favorites
//! as authorization. Native owners supply events only after explicit enablement.
pub mod engine;
pub mod pairing;
pub mod runtime;
pub mod secure_channel;
