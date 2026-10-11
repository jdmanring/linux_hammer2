## 3.2.5.19.2 Receiving a Lease Break Notification

If **Connection.Dialect** is not "2.0.2", the client MUST verify:

If **Connection.SupportsDirectoryLeasing** is TRUE or **Connection.SupportsFileLeasing** is TRUE, the client MUST perform the following:

- The client MUST locate the file in the **GlobalFileTable** using the **LeaseKey** in the [Lease Break Notification](9abe6f73-f32f-4a23-998d-ee9da2b90e2e). If a file is not found, no further processing is required.
- If a File entry is located, the client MUST take action based on the **File.LeaseState** and the new LeaseState that is received in the Lease Break Notification.
- If **File.LeaseState** includes SMB2\_LEASE\_WRITE\_CACHING and the new LeaseState does not include SMB2\_LEASE\_WRITE\_CACHING, the client MUST flush any cached data associated with this file by issuing one or more SMB2 WRITE requests as described in [3.2.4.7](49dce94d-71fd-4fdf-b730-a60d6b27fbba). It MUST also flush out any cached byte-range locks it has on the file by enumerating the **File.OpenTable** and for each open, send the cached byte-range locks by issuing SMB2 LOCK requests as described in [3.2.4.19](06d42500-2ead-4659-8af2-86dcaec5286e).
- If **File.LeaseState** includes SMB2\_LEASE\_READ\_CACHING and the new LeaseState does not include SMB2\_LEASE\_READ\_CACHING, the client MUST notify the application to purge cached data for the **File**.
- If **File.LeaseState** includes SMB2\_LEASE\_HANDLE\_CACHING and the new LeaseState does not include SMB2\_LEASE\_HANDLE\_CACHING, the client MUST enumerate all handles in **File.OpenTable** and close any cached handles that have already been closed by the application. The close process is described in [3.2.4.5](fcc1cd9a-f2c5-489d-bf90-143826b3041e).
- If **Connection.Dialect** belongs to the SMB 3.x dialect family and **File.LeaseState** is equal to the new LeaseState and (**NewEpoch** - **File.LeaseEpoch**) is greater than 1, the client MUST notify the application to purge cached data for the **File**.
- If **Connection.Dialect** belongs to the SMB 3.x dialect family and **NewEpoch** is not equal to **File.LeaseEpoch** and (**NewEpoch – File.LeaseEpoch**) is less than or equal to 32767, the client MUST copy the new **LeaseState** into **File.LeaseState**. The client MUST set **File.LeaseEpoch** to **NewEpoch**.
- Otherwise, if **Connection.Dialect** is "2.1", the new LeaseState granted by the server in the Lease Break Notification MUST be copied to **File.LeaseState**.
- If a lease acknowledgment is required by the server as indicated by the SMB2\_NOTIFY\_BREAK\_LEASE\_FLAG\_ACK\_REQUIRED bit in the **Flags** field of the Lease Break Notification, the client SHOULD [<202>](a64e55aa-1152-48e4-8206-edd96444e7f7#Appendix_A_202) send a [Lease Break Acknowledgment](048aae06-3421-418b-85b3-0f7605749596) request described as follows.
	- If all open handles on this file are closed (that is, **File.OpenTable** is empty for this file), the client SHOULD consider it as an implicit acknowledgment of the lease break. No explicit acknowledgment is required.
	- The client MUST construct a Lease Break Acknowledgment request following the syntax specified in 2.2.24.2. The LeaseKey in the request MUST be set to **File.LeaseKey** and the LeaseState in the request MUST be set to **File.LeaseState**.
	- The client MUST choose an Open from among the remaining opens in **File.OpenTable** and it MUST be used to send the acknowledgment to the server, via the connection identified by **Open.Connection**.
		- The [SMB2 header](5cd64522-60b3-4f3e-a157-fe66f1228052) is initialized as follows:
			- **Command** MUST be set to SMB2 OPLOCK\_BREAK.
			- The **MessageId** field is set as specified in section [3.2.4.1.3](5c5f5316-9936-417b-9221-4686de25d414).
			- The client MUST set **SessionId** to **Open.TreeConnect.Session.SessionId**.
			- The client MUST set **TreeId** to **Open.TreeConnect.TreeConnectId**.
