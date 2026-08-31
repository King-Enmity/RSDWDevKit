# Common source

Place code here only when it is valid for both client and dedicated-server packages.

Shared modules must not assume a viewport, local PlayerController, local pawn, UMG, hotkeys, or camera exists. If player context is required, accept it explicitly from the caller.
