// SPDX-License-Identifier: MIT

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import {IPancakeRouter02} from "./pancakeRouter.sol";

pragma solidity ^0.8.0;

contract CustomisedEscrow {

    using SafeMath for uint256;
    using Address for address payable;

    enum State{initiated,delivered,paid,disputed}

    struct instance{
        uint256 id;
        address buyer;
        address payable seller;
        bool payType; // true if BNB/false if tokens
        uint256[] amounts;
        bool sellerConfirmation;
        bool buyerConfirmation;
        uint256 start;
        uint256 timeInDays;
        State currentState;
    }

    // variables

    address public owner;

    mapping(address=>uint256) public AddressEscrowMap;

    mapping(address=>uint256) public balances;

    address payable private withdrawAddress;

    uint256[] disputedEscrows;

    mapping(address=>bool) public admins;

    address public token;

    uint8 public ownerCut;

    uint8 public PoolCut; 

    address public liquidityPool;

    mapping(uint256=>instance) public getEscrow;

    mapping(uint256=>uint256) public escrowAmtsBNB;

    mapping(uint256=>uint256) public escrowAmtsToken;

    mapping (uint256=>bool) approvedForWithdraw;

    mapping(uint256=> address) disputedRaisedBy;

    uint256 public totalEscrows;

    uint256 public timeLimitInDays;

    // events

    event EscrowCreated(
        uint256 id,
        address buyer,
        address payable seller,
        bool payType,
        uint256[] amounts,
        uint256 start,
        uint256 timeInDays,
        State currentState
    );

    event StateChanged(uint256 indexed id,State indexed _state);

    //modifiers

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    modifier onlyAdmin() {
        require(admins[msg.sender]==true);
        _;
    }

    modifier onlyBuyer(uint _id){
        require(msg.sender == getEscrow[_id].buyer);
        _;
    }

    modifier onlySeller(uint _id){
        require(msg.sender == getEscrow[_id].seller);
        _;
    }

    constructor(address _token,uint256 _timeLimitInDays,address _liquidityPool){
        owner = msg.sender;
        token = _token;
        liquidityPool = _liquidityPool;
        totalEscrows =0;
        timeLimitInDays = _timeLimitInDays;
    }

    function arraySum(uint256[] memory array) internal pure returns (uint256) {
        require(array.length >1);
        uint256 sum = 0;
        for (uint256 i = 0; i < array.length-1; i++) {
            sum = SafeMath.add(sum,array[i]);
        }
        return sum;
    }

    function createEscrowBNB(address payable _seller,uint256[] memory amts,uint256 timeInDays) public payable{
        require(msg.value >= arraySum(amts));
        require(timeInDays <= timeLimitInDays,"timePeriod more than limit");
        totalEscrows++;
        uint256 id = totalEscrows;
        getEscrow[id]= instance(id,msg.sender,_seller,true,amts,false,false,block.timestamp,timeInDays,State.initiated);
        escrowAmtsBNB[id] = msg.value;
        AddressEscrowMap[msg.sender] = id;
        approvedForWithdraw[id] = false;
        emit EscrowCreated(id,msg.sender,_seller,true,amts,block.timestamp,timeInDays,State.initiated);
    }

    function createEscrowToken(address payable _seller,uint256[] memory amts,uint256 timeInDays) public {
        uint amt = arraySum(amts);
        require(IERC20(token).balanceOf(msg.sender) >= amt);
        require(IERC20(token).transferFrom(msg.sender,address(this),amt));
        require(timeInDays <= timeLimitInDays,"timePeriod more than limit");
        totalEscrows++;
        uint256 id = totalEscrows;
        getEscrow[id]= instance(id,msg.sender,_seller,false,amts,false,false,block.timestamp,timeInDays,State.initiated);
        escrowAmtsToken[id] = amt;
        AddressEscrowMap[msg.sender] = id;
        emit EscrowCreated(id,msg.sender,_seller,false,amts,block.timestamp,timeInDays,State.initiated);
    }

    function updateDelivery(uint256 _id) public onlyBuyer(_id){
        require(block.timestamp <= SafeMath.mul(getEscrow[_id].timeInDays,86400),"Escrow Period exceeded");
        require(getEscrow[_id].sellerConfirmation,"Seller has not Confirmed delivery");
        require(!getEscrow[_id].buyerConfirmation,"Buyer already confirmed");
        require(!approvedForWithdraw[_id]);
        delete getEscrow[_id];
        uint256 _PoolCut = ceilDiv(SafeMath.mul(PoolCut,escrowAmtsBNB[_id]),1000);
        if(getEscrow[_id].payType){
            uint256 OwnerCut = ceilDiv(SafeMath.mul(ownerCut,escrowAmtsBNB[_id]),1000);
            uint256 temp= escrowAmtsBNB[_id];
            escrowAmtsBNB[_id] = 0;
            getEscrow[_id].seller.sendValue(temp-OwnerCut-_PoolCut);
            withdrawAddress.sendValue(OwnerCut);
        }else if(!getEscrow[_id].payType){
            uint256 OwnerCut = ceilDiv(SafeMath.mul(ownerCut,escrowAmtsToken[_id]),1000);
            uint256 temp = escrowAmtsToken[_id];
            escrowAmtsToken[_id] = 0;   
            IERC20(token).transfer(getEscrow[_id].seller,temp-OwnerCut-_PoolCut);
            IERC20(token).transfer(withdrawAddress,OwnerCut);
        }
        getEscrow[_id].buyerConfirmation=true;
        getEscrow[_id].currentState = State.paid;
    }

    function updateSellerStatus(uint256 _id) public onlySeller(_id){
        require(block.timestamp <= SafeMath.mul(getEscrow[_id].timeInDays,86000),"Escrow Period exceeded");
        require(getEscrow[_id].currentState == State.initiated);
        require(!approvedForWithdraw[_id]);
        require(!getEscrow[_id].buyerConfirmation,"buyer already confirmed");
        getEscrow[_id].sellerConfirmation = true;
        getEscrow[_id].currentState = State.delivered;
        emit StateChanged(_id,getEscrow[_id].currentState);
    }

    function raiseDispute(uint256 id) public{
        require(msg.sender == getEscrow[id].seller || msg.sender == getEscrow[id].buyer);
        require(!getEscrow[id].buyerConfirmation || !getEscrow[id].sellerConfirmation);
        require(!approvedForWithdraw[id]);
        require(getEscrow[id].currentState != State.disputed);
        getEscrow[id].currentState = State.disputed;
        disputedEscrows.push(id);
        disputedRaisedBy[id] == msg.sender;
        emit StateChanged(id, getEscrow[id].currentState);
    }

    function approveForWithdraw(uint256 id,bool withdrawParty) public onlyOwner{
        // withdrawParty -- true if buyer,false if seller 
        require(getEscrow[id].currentState == State.disputed);
        if(withdrawParty){
            payable(getEscrow[id].buyer).sendValue(escrowAmtsBNB[id]);
        }
        else if(!withdrawParty){
            getEscrow[id].seller.sendValue(escrowAmtsBNB[id]);
        }
    }

    function changeToken(address _token) public onlyOwner{
        token = _token;
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a / b + (a % b == 0 ? 0 : 1);
    }

    receive() external payable {
        balances[msg.sender] += msg.value;
    }

}