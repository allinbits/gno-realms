# AIB Gno realms

This repository centralizes the gno realms & packages of AllInBits. It contains
mainly the IBC realms and theirs dependencies.

Originally the code [intended](https://github.com/gnolang/gno/pull/4655) to be
part of gno.land/gno/examples, but realisticly it became too big to be reviewed
and added there.

## IBC Core

See [IBC Core README].

## IBC Applications

The `r/aib/ibc/apps` realm provides applications that implement the
`p/aib/ibc/app.IBCApp` interface. Such apps must be registered into the core
module using the `core.RegisterApp()` function.

### Writing an application

An application realm implements the four `IBCApp` callbacks (`OnSendPacket`,
`OnRecvPacket`, `OnTimeoutPacket`, `OnAcknowledgementPacket`) and registers
itself with the core from its `init`:

```gno
func init(cur realm) {
	core.RegisterApp(cross(cur), PortID, &App{})
}
```

**Every callback must first assert that it is being invoked by the core
realm.** The callbacks are exported methods, and any realm can obtain a usable
value of the app type with a zero-value declaration (`var app myapp.App`), so
without this check a foreign realm can call `OnRecvPacket`, or the refund
callbacks, to mint or release funds with no proof and no core involvement. Core
crosses into the app, so `cur.Previous()` is the core realm on every legitimate
call:

```gno
func (a *App) OnRecvPacket(cur realm, sourceClient, destinationClient string,
	sequence uint64, payload types.Payload) types.RecvPacketResult {
	if cur.Previous().PkgPath() != "gno.land/r/aib/ibc/core" {
		panic("callback must be invoked by the IBC core")
	}
	// ...
}
```

See `assertCoreCaller` in the transfer application for the shared helper, and
its `*_foreign_caller_filetest.gno` filetests for the expected behaviour.

Registration is immediate for realms under `gno.land/r/aib/`. From any other
realm it stays pending until the core's authority approves it (`ApproveApp`,
directly or through a GovDAO proposal), so a third-party application should
expose a way to register after approval rather than only from `init`.

### Transfer Application

See [Transfer Application README].

## Testing

Run `make gnodev` to start a local gno node with all the realms and packages
from this repo.

Check http://localhost:8888/r/aib/ibc/core$help to list the available
functions. This help page also gives instructions to call the functions, but
only with `MsgCall`. This kind of call won't work with most of the IBC
functions, because they use complex args (see [README][IBC Core Readme]).

Once created, clients are visible here http://localhost:8888/r/aib/ibc/core:clients

[IBC Core README]: ./gno.land/r/aib/ibc/core/README.md
[Transfer Application README]: ./gno.land/r/aib/ibc/apps/transfer/README.md
