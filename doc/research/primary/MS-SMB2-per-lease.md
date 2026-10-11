## 3.3.1.12 Per Lease

If the server implements the SMB 2.1 or SMB 3.x dialect family and supports leasing, it implements the following:

- **Lease.LeaseKey**: The 128-bit client-generated identifier for this lease.
- **Lease.ClientLeaseId**: The 128-bit implementation-defined server identifier for this lease.
- **Lease.Filename**: The name of the file backing this lease.
- **Lease.LeaseState**: The current state of the lease as indicated by the underlying object store. This value MUST be a combination of the flags described in section [2.2.13.2.8](250a5100-f8b0-4b32-a202-f592ce4c05e7) for "LeaseState". For the remainder of section [3.3](461decc5-61bb-4885-8e2d-4ef898f10e6f), these will be referred to as follows:
	| Lease State | Abbreviated Name |
	| --- | --- |
	| 0 | NONE |
	| SMB2\_LEASE\_READ\_CACHING | R |
	| SMB2\_LEASE\_READ\_CACHING \| SMB2\_LEASE\_WRITE\_CACHING | RW |
	| SMB2\_LEASE\_READ\_CACHING \| SMB2\_LEASE\_HANDLE\_CACHING | RH |
	| SMB2\_LEASE\_READ\_CACHING \| SMB2\_LEASE\_WRITE\_CACHING \| SMB2\_LEASE\_HANDLE\_CACHING | RWH |
- **Lease.BreakToLeaseState**: The state to which the lease is breaking. This value MUST be a combination of the flags described in section 2.2.13.2.8 for " **LeaseState** ". For the remainder of section 3.3, these will be referred to as described in the table above.
- **Lease.LeaseBreakTimeout**: The time value that indicates when a lease that is breaking and has not received a [Lease Break Acknowledgment](ba268951-db69-4eeb-9e21-917dda0df9e8) from the client will be acknowledged by the server to the underlying object store.
- **Lease.LeaseOpens**: The list of opens associated with this lease.
- **Lease.Breaking**: A Boolean, if set to TRUE, indicating a lease break requiring acknowledgement is in progress.
- **Lease.Held**: A Boolean, if set to TRUE, indicating that at least one **Open** is associated with this lease.
- **Lease.BreakNotification**: A Lease Break Notification, as specified in section [2.2.23.2](9abe6f73-f32f-4a23-998d-ee9da2b90e2e), if any, to be sent to the client.
- **Lease.FileDeleteOnClose**: A Boolean, if set to TRUE, indicating that file deletion on close is pending.

If the server implements the SMB 3.x dialect family and supports leasing, it implements the following:

- **Lease.Epoch**: A sequence number incremented by the server on every lease state change.
- **Lease.ParentLeaseKey**: The 128-bit client-generated identifier of the lease for the parent directory of this lease.
- **Lease.Version**: A number indicating the lease version.
