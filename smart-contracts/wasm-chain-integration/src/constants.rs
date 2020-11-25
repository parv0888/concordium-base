/// Maximum size of contract state in bytes.
pub const MAX_CONTRACT_STATE: u32 = 16384; // 16kB

/// Maximum number of nested function calls.
pub const MAX_ACTIVATION_FRAMES: u32 = 1024;

/// Maximum size of the init/receive parameter.
pub const MAX_PARAMETER_SIZE: usize = 1024;
