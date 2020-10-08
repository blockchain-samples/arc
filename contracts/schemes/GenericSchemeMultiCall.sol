pragma solidity 0.5.17;
pragma experimental ABIEncoderV2;

import "@daostack/infra/contracts/votingMachines/IntVoteInterface.sol";
import "@daostack/infra/contracts/votingMachines/ProposalExecuteInterface.sol";
import "../votingMachines/VotingMachineCallbacks.sol";
import "./SchemeConstraints.sol";


/**
 * @title GenericSchemeMultiCall.
 * @dev  A scheme for proposing and executing calls to multiple arbitrary function
 * on one or multiple contracts on behalf of the organization avatar.
 */
contract GenericSchemeMultiCall is VotingMachineCallbacks, ProposalExecuteInterface {
    using SafeMath for uint256;

    // Details of a voting proposal:
    struct MultiCallProposal {
        address[] contractsToCall;
        bytes[] callsData;
        uint256[] values;
        bool exist;
        bool passed;
    }

    mapping(bytes32=>MultiCallProposal) public proposals;
    IntVoteInterface public votingMachine;
    bytes32 public voteParams;
    mapping(address=>bool) public contractsWhitelist;
    Avatar public avatar;
    bytes4 private constant APPROVE_SIGNATURE = 0x095ea7b3;//approve(address,uint256)
    SchemeConstraints public schemeConstraints;

    event NewMultiCallProposal(
        address indexed _avatar,
        bytes32 indexed _proposalId,
        bytes[]   _callsData,
        uint256[] _values,
        string  _descriptionHash,
        address[] _contractsToCall
    );

    event ProposalExecuted(
        address indexed _avatar,
        bytes32 indexed _proposalId
    );

    event ProposalCallExecuted(
        address indexed _avatar,
        bytes32 indexed _proposalId,
        address _contractToCall,
        bytes _callData,
        bytes _callDataReturnValue
    );

    event ProposalExecutedByVotingMachine(
        address indexed _avatar,
        bytes32 indexed _proposalId,
        int256 _param
    );

    event ProposalDeleted(address indexed _avatar, bytes32 indexed _proposalId);

    event WhiteListedContracts(address indexed _avatar, address[] _contractsWhitelist);

    /* @dev initialize
     * @param _avatar the avatar to mint reputation from
     * @param _votingMachine the voting machines address to
     * @param _voteParams voting machine parameters.
     * @param _contractsWhitelist the contracts the scheme is allowed to interact with
     *
     */
    function initialize(
        Avatar _avatar,
        IntVoteInterface _votingMachine,
        bytes32 _voteParams,
        address[] calldata _contractsWhitelist,
        SchemeConstraints _schemeConstraints
    )
    external
    {
        require(avatar == Avatar(0), "can be called only one time");
        require(_avatar != Avatar(0), "avatar cannot be zero");
        require(_contractsWhitelist.length > 0, "contractsWhitelist cannot be empty");
        avatar = _avatar;
        votingMachine = _votingMachine;
        voteParams = _voteParams;
        schemeConstraints = _schemeConstraints;

        for (uint i = 0; i < _contractsWhitelist.length; i++) {
            contractsWhitelist[_contractsWhitelist[i]] = true;
        }
        emit WhiteListedContracts(address(avatar), _contractsWhitelist);
    }

    /**
    * @dev execution of proposals, can only be called by the voting machine in which the vote is held.
    * @param _proposalId the ID of the voting in the voting machine
    * @param _decision a parameter of the voting result, 1 yes and 2 is no.
    * @return bool success
    */
    function executeProposal(bytes32 _proposalId, int256 _decision)
    external
    onlyVotingMachine(_proposalId)
    returns(bool) {
        MultiCallProposal storage proposal = proposals[_proposalId];
        require(proposal.exist, "must be a live proposal");
        require(!proposal.passed, "cannot execute twice");

        if (_decision == 1) {
            proposal.passed = true;
        } else {
            delete proposals[_proposalId];
            emit ProposalDeleted(address(avatar), _proposalId);
        }

        emit ProposalExecutedByVotingMachine(address(avatar), _proposalId, _decision);
        return true;
    }

    /**
    * @dev execution of proposals after it has been decided by the voting machine
    * @param _proposalId the ID of the voting in the voting machine
    */
    function execute(bytes32 _proposalId) external {
        MultiCallProposal storage proposal = proposals[_proposalId];
        require(proposal.exist, "must be a live proposal");
        require(proposal.passed, "proposal must passed by voting machine");
        proposal.exist = false;
        bytes memory genericCallReturnValue;
        bool success;
        Controller controller = Controller(avatar.owner());
        for (uint i = 0; i < proposal.contractsToCall.length; i++) {
            bytes memory callData = proposal.callsData[i];
            require(schemeConstraints.isAllowedToCall(proposal.contractsToCall[i], callData, avatar, proposal.values[i]),
            "call is not allowed");
            (success, genericCallReturnValue) =
            controller.genericCall(proposal.contractsToCall[i], callData, avatar, proposal.values[i]);
            /* Whole transaction will be reverted if at least one call fails*/
            require(success, "Proposal call failed");
            emit ProposalCallExecuted(
                address(avatar),
                _proposalId,
                proposal.contractsToCall[i],
                callData,
                genericCallReturnValue
            );
        }

        delete proposals[_proposalId];
        emit ProposalDeleted(address(avatar), _proposalId);
        emit ProposalExecuted(address(avatar), _proposalId);
    }

    /**
    * @dev propose to call one or multiple contracts on behalf of the _avatar
    *      The function trigger NewMultiCallProposal event
    * @param _contractsToCall the contracts to be called
    * @param _callsData - The abi encode data for the calls
    * @param _values value(ETH) to transfer with the calls
    * @param _descriptionHash proposal description hash
    * @return an id which represents the proposal
    * Note: The reasone this function is public(and not 'external') is due to
    *       known compiler issue handling calldata bytes[] still not solved in 0.5.17
    *       see : https://github.com/ethereum/solidity/issues/6835#issuecomment-549895381
    */
    function proposeCalls(
        address[] memory _contractsToCall,
        bytes[] memory _callsData,
        uint256[] memory _values,
        string memory _descriptionHash
    )
    public
    returns(bytes32 proposalId)
    {
        require(
            (_contractsToCall.length == _callsData.length) && (_contractsToCall.length == _values.length),
            "Wrong length of _contractsToCall, _callsDataLens or _values arrays"
        );
        for (uint i = 0; i < _contractsToCall.length; i++) {
            if (!contractsWhitelist[_contractsToCall[i]]) {
                address spender;
                bytes memory callData = _callsData[i];
                require(
                    callData[0] == APPROVE_SIGNATURE[0] &&
                    callData[1] == APPROVE_SIGNATURE[1] &&
                    callData[2] == APPROVE_SIGNATURE[2] &&
                    callData[3] == APPROVE_SIGNATURE[3],
                "allow only approve call for none whitelistedContracts");
                //in solidity > 6 this can be replaced by:
                //(spender,) = abi.decode(callData[4:], (address, uint));
                // see https://github.com/ethereum/solidity/issues/9439
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    spender := mload(add(callData, 36))
                }
                require(contractsWhitelist[spender], "spender contract not whitelisted");
            }
        }

        proposalId = votingMachine.propose(2, voteParams, msg.sender, address(avatar));

        proposals[proposalId] = MultiCallProposal({
            contractsToCall: _contractsToCall,
            callsData: _callsData,
            values: _values,
            exist: true,
            passed: false
        });
        proposalsInfo[address(votingMachine)][proposalId] = ProposalInfo({
            blockNumber:block.number,
            avatar:avatar
        });

        emit NewMultiCallProposal(address(avatar), proposalId, _callsData, _values, _descriptionHash, _contractsToCall);
    }
}
