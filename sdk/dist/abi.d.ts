export declare const REGISTRY_ABI: readonly [{
    readonly type: "function";
    readonly name: "registerAgent";
    readonly stateMutability: "payable";
    readonly inputs: readonly [{
        readonly name: "metadataHash";
        readonly type: "bytes32";
    }];
    readonly outputs: readonly [{
        readonly name: "agentId";
        readonly type: "uint256";
    }];
}, {
    readonly type: "function";
    readonly name: "logReceipt";
    readonly stateMutability: "nonpayable";
    readonly inputs: readonly [{
        readonly name: "agentId";
        readonly type: "uint256";
    }, {
        readonly name: "receiptHash";
        readonly type: "bytes32";
    }];
    readonly outputs: readonly [];
}, {
    readonly type: "function";
    readonly name: "reputation";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly name: "agentId";
        readonly type: "uint256";
    }];
    readonly outputs: readonly [{
        readonly name: "";
        readonly type: "int256";
    }];
}, {
    readonly type: "function";
    readonly name: "agents";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly name: "";
        readonly type: "uint256";
    }];
    readonly outputs: readonly [{
        readonly name: "principal";
        readonly type: "address";
    }, {
        readonly name: "metadataHash";
        readonly type: "bytes32";
    }, {
        readonly name: "registeredAt";
        readonly type: "uint64";
    }, {
        readonly name: "active";
        readonly type: "bool";
    }, {
        readonly name: "selfReceipts";
        readonly type: "uint64";
    }, {
        readonly name: "attestedReceipts";
        readonly type: "uint64";
    }, {
        readonly name: "disputes";
        readonly type: "uint64";
    }];
}, {
    readonly type: "function";
    readonly name: "registrationFee";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly name: "";
        readonly type: "uint256";
    }];
}, {
    readonly type: "function";
    readonly name: "deactivate";
    readonly stateMutability: "nonpayable";
    readonly inputs: readonly [{
        readonly name: "agentId";
        readonly type: "uint256";
    }];
    readonly outputs: readonly [];
}, {
    readonly type: "function";
    readonly name: "attestReceipt";
    readonly stateMutability: "nonpayable";
    readonly inputs: readonly [{
        readonly name: "agentId";
        readonly type: "uint256";
    }, {
        readonly name: "receiptHash";
        readonly type: "bytes32";
    }];
    readonly outputs: readonly [];
}, {
    readonly type: "function";
    readonly name: "attestor";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly name: "";
        readonly type: "uint256";
    }, {
        readonly name: "";
        readonly type: "bytes32";
    }];
    readonly outputs: readonly [{
        readonly name: "";
        readonly type: "address";
    }];
}, {
    readonly type: "event";
    readonly name: "AgentRegistered";
    readonly inputs: readonly [{
        readonly name: "agentId";
        readonly type: "uint256";
        readonly indexed: true;
    }, {
        readonly name: "principal";
        readonly type: "address";
        readonly indexed: true;
    }, {
        readonly name: "metadataHash";
        readonly type: "bytes32";
        readonly indexed: false;
    }];
}, {
    readonly type: "event";
    readonly name: "ReceiptLogged";
    readonly inputs: readonly [{
        readonly name: "agentId";
        readonly type: "uint256";
        readonly indexed: true;
    }, {
        readonly name: "receiptHash";
        readonly type: "bytes32";
        readonly indexed: true;
    }];
}, {
    readonly type: "event";
    readonly name: "ReceiptAttested";
    readonly inputs: readonly [{
        readonly name: "agentId";
        readonly type: "uint256";
        readonly indexed: true;
    }, {
        readonly name: "receiptHash";
        readonly type: "bytes32";
        readonly indexed: true;
    }, {
        readonly name: "validator";
        readonly type: "address";
        readonly indexed: true;
    }];
}];
//# sourceMappingURL=abi.d.ts.map