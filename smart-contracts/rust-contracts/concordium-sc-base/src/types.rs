/// A type representing the constract state bytes.
#[derive(Default)]
pub struct ContractState {
    pub(crate) current_position: u32,
}

#[derive(Default)]
/// A type representing the parameter to init and receive methods.
pub struct Parameter {
    pub(crate) current_position: u32,
}

/// A type representing the logger.
#[derive(Default)]
pub struct Logger {
    pub(crate) _private: (),
}

/// Actions that can be produced at the end of a contract execution. This
/// type is deliberately not cloneable so that we can enforce that
/// `and_then` and `or_else` can only be used when more than one event is
/// created.
///
/// This type is marked as `must_use` since functions that produce
/// values of the type are effectful.
#[must_use]
pub struct Action {
    pub(crate) _private: u32,
}

impl Action {
    pub fn tag(&self) -> u32 { self._private }
}

/// A non-descript error message, signalling rejection of a smart contract
/// invocation.
#[derive(Default, Eq, PartialEq)]
pub struct Reject {}

// Macros for failing a contract function

/// The `bail` macro can be used for cleaner error handling. If the function has
/// result type Result<_, Reject> then invoking `bail` will terminate execution
/// early with an error. If the macro is invoked with a string message the
/// message will be logged before the function terminates.
#[macro_export]
macro_rules! bail {
    () => {{
        return Err(Default::default());
    }};
    ($arg:expr) => {{
        // format_err!-like formatting
        // logs are only retained in case of rejection when testing.
        return Err($arg);
    }};
}

/// The `ensure` macro can be used for cleaner error handling. It is analogous
/// to `assert`, but instead of panicking it uses `bail` to terminate execution
/// of the function early.
#[macro_export]
macro_rules! ensure {
    ($p:expr) => {
        if !$p {
            $crate::bail!();
        }
    };
    ($p:expr, $arg:expr) => {{
        if !$p {
            $crate::bail!($arg);
        }
    }};
}

/// ## Variants of `ensure` for ease of use in certain contexts.
/// Ensure the first two arguments are equal, using `bail` otherwise.
#[macro_export]
macro_rules! ensure_eq {
    ($l:expr, $r:expr) => {
        $crate::ensure!($l == $r)
    };
    ($l:expr, $r:expr, $arg:expr) => {
        $crate::ensure!($l == $r, $arg)
    };
}

#[macro_export]
/// Ensure the first two arguments are __not__ equal, using `bail` otherwise.
macro_rules! ensure_ne {
    ($l:expr, $r:expr) => {
        $crate::ensure!($l != $r)
    };
    ($l:expr, $r:expr, $arg:expr) => {
        $crate::ensure!($l != $r, $arg)
    };
}

// Macros for failing a test

/// The `fail` macro is used for testing as a substitute for the panic macro.
/// It reports back error information to the host.
/// Used only in testing.
#[macro_export]
macro_rules! fail {
    () => {
        {
            $crate::test_infrastructure::report_error("", file!(), line!(), column!());
            panic!()
        }
    };
    ($($arg:tt),+) => {
        {
            let msg = format!($($arg),+);
            $crate::test_infrastructure::report_error(&msg, file!(), line!(), column!());
            panic!(msg)
        }
    };
}

/// The `claim` macro is used for testing as a substitute for the assert macro.
/// It checks the condition and if false it reports back an error.
/// Used only in testing.
#[macro_export]
macro_rules! claim {
    ($cond:expr) => {
        if !$cond {
            $crate::fail!()
        }
    };
    ($cond:expr,) => {
        if !$cond {
            $crate::fail!()
        }
    };
    ($cond:expr, $($arg:tt),+) => {
        if !$cond {
            $crate::fail!($($arg),+)
        }
    };
}

/// Ensure the first two arguments are equal, just like `assert_eq!`, otherwise
/// reports an error. Used only in testing.
#[macro_export]
macro_rules! claim_eq {
    ($left:expr, $right:expr) => {
        $crate::claim!($left == $right, "left and right are not equal\nleft: {:?}\nright: {:?}", $left, $right)
    };
    ($left:expr, $right:expr,) => {
        $crate::claim_eq!($left, $right)
    };
    ($left:expr, $right:expr, $($arg:tt),+) => {
        $crate::claim!($left == $right, $($arg),+)
    };
}

/// Ensure the first two arguments are *not* equal, just like `assert_ne!`,
/// otherwise reports an error.
/// Used only in testing.
#[macro_export]
macro_rules! claim_ne {
    ($left:expr, $right:expr) => {
        $crate::claim!($left != $right)
    };
    ($left:expr, $right:expr,) => {
        $crate::claim!($left != $right)
    };
    ($left:expr, $right:expr, $($arg:tt),+) => {
        $crate::claim!($left != $right, $($arg),+)
    };
}

/// The expected return type of the receive method of a smart contract.
pub type ReceiveResult<A> = Result<A, Reject>;

/// The expected return type of the init method of the smart contract,
/// parametrized by the state type of the smart contract.
pub type InitResult<S> = Result<S, Reject>;

pub struct InitContextExtern {}

pub struct ReceiveContextExtern {}

pub struct ChainMetaExtern {}
