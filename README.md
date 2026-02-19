# AIB Gno realms

This repository centralizes the gno realms & packages of AllInBits. It contains
mainly the IBC realms and theirs dependencies.

Originally the code [intended](https://github.com/gnolang/gno/pull/4655) to be
part of gno.land/gno/examples, but realisticly it became too big to be reviewed
and added there.

## IBC Core

See [IBC Core README].

## IBC Applications

The `r/aib/ibc/apps` realm provides applications that implements the
`p/aib/ibc/app.IBCApp` interface. Such apps must be registered into the core
module using the `core.RegisterApp()` function.

### Transfer Application

Located in `r/aib/ibc/apps/transfer`, the Transfer application allows token
transfer between 2 IBC connected chains. It's the gno version of
`ibc-go/modules/apps/transfer` application.

## Testing

Run `make gnodev` to start a local gno node with all the realms and packages
from this repo.

Check http://localhost:8888/r/aib/ibc/core$help to list the available
functions. This help page also gives instructions to call the functions, but
only with `MsgCall`. This kind of call won't work with most of the IBC
functions, because they use complex args (see [README][IBC Core Readme]).

Once created, clients are visible here http://localhost:8888/r/aib/ibc/core:clients

[IBC Core README]: ./gno.land/r/aib/ibc/core/README.md
