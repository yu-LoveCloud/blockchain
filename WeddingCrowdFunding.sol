// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ERC20 Token 표준 인터페이스
interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

// ReentrancyGuard 대신 재진입 방지를 위한 재진입 방지 구현
contract ReentrancyGuard {
    bool private _notEntered;

    constructor() {
        _notEntered = true;
    }

    modifier nonReentrant() {
        require(_notEntered, "ReentrancyGuard: reentrant call");
        _notEntered = false;
        _;
        _notEntered = true;
    }
}

// WeddingCrowdfunding 컨트랙트
contract WeddingCrowdfunding is ReentrancyGuard {
    IERC20 public tokenContract;
    address public companyWallet;

    struct Crowdfunding {
        address couple;
        uint256 goal;
        uint256 endTime;
        uint256 totalCollected;
        bool active;
        bool canceled; //펀딩의 상태
        bool orderCanceled; // 주문 취소 상태
        mapping(address => uint256) contributions;
    }

    mapping(uint256 => Crowdfunding) public crowdfundings;
    uint256 public crowdfundingCount;

    // 이벤트 선언
    event CrowdfundingCreated(uint256 indexed crowdfundingId, address couple, uint256 goal, uint256 endTime);
    event ContributionMade(uint256 indexed crowdfundingId, address indexed guest, uint256 amount);
    event CrowdfundingCompleted(uint256 indexed crowdfundingId, uint256 totalCollected);
    event CrowdfundingCanceled(uint256 indexed crowdfundingId);
    event Refund(address indexed guest, uint256 amount);

    // 생성자 함수
    constructor(IERC20 _tokenContract, address _companyWallet) {
        tokenContract = _tokenContract;
        companyWallet = _companyWallet;
    }

    // 1. 펀딩 생성 (부부가 호출)
    function createCrowdfunding(uint256 _goal, uint256 _duration) external returns (uint256) {
        crowdfundingCount++;
        Crowdfunding storage newCrowdfunding = crowdfundings[crowdfundingCount];
        newCrowdfunding.couple = msg.sender;
        newCrowdfunding.goal = _goal;
        newCrowdfunding.endTime = block.timestamp + _duration;
        newCrowdfunding.active = true;
        newCrowdfunding.canceled = false; // 초기 상태는 취소되지 않음
        newCrowdfunding.orderCanceled = false; //초기 주문상태는 취소되지 않음

        emit CrowdfundingCreated(crowdfundingCount, msg.sender, _goal, newCrowdfunding.endTime);
        return crowdfundingCount;
    }

    // 2. 펀딩 참여 (하객이 승인 후 기부, 최대 한 번만 가능)
    function contribute(uint256 _crowdfundingId, uint256 _amount) external nonReentrant {
        Crowdfunding storage crowdfunding = crowdfundings[_crowdfundingId];
        require(crowdfunding.active, "The crowdfunding is not active.");
        require(!crowdfunding.canceled, "The crowdfunding has been canceled.");
        require(block.timestamp < crowdfunding.endTime, "The crowdfunding has ended.");
        require(crowdfunding.contributions[msg.sender] == 0, "You have already contributed.");

        // 하객이 사전에 승인(approve)했는지 확인
        require(tokenContract.allowance(msg.sender, address(this)) >= _amount, "Insufficient allowance.");

        tokenContract.mint(msg.sender, _amount);
        // 하객의 토큰을 펀딩 지갑으로 전송
        tokenContract.transferFrom(msg.sender, address(this), _amount);

        crowdfunding.contributions[msg.sender] = _amount;
        crowdfunding.totalCollected += _amount;

        if (crowdfunding.totalCollected >= crowdfunding.goal) {
            crowdfunding.active = false;
        }

        emit ContributionMade(_crowdfundingId, msg.sender, _amount);
    }

    // 3. 펀딩 금액 달성 후 주문 완료 (부부가 호출)
    function completeOrder(uint256 _crowdfundingId) external nonReentrant {
        Crowdfunding storage crowdfunding = crowdfundings[_crowdfundingId];
        require(msg.sender == crowdfunding.couple, "Only the couple can complete the order.");
        require(!crowdfunding.canceled, "The crowdfunding has been canceled.");
        require(!crowdfunding.active, "The crowdfunding has not ended yet.");

        uint256 totalCollected = crowdfunding.totalCollected;
        tokenContract.transfer(companyWallet, totalCollected);

        crowdfunding.orderCanceled = false; //주문취소 상태를 false로 변경

        emit CrowdfundingCompleted(_crowdfundingId, totalCollected);
    }

    // 주문 취소 메소드 (펀딩은 완료된 상태에서 주문만 취소)
    function cancelOrder(uint256 _crowdfundingId) external nonReentrant {
        Crowdfunding storage crowdfunding = crowdfundings[_crowdfundingId];
        
        // 조건: 부부만 주문 취소 가능
        require(msg.sender == crowdfunding.couple, "Only the couple can cancel the order.");
        
        // 조건: 펀딩은 완료된 상태여야 함
        require(!crowdfunding.active, "The crowdfunding is still active.");
        
        // 조건: 이미 취소된 주문이 아니어야 함
        require(!crowdfunding.orderCanceled, "The order has already been canceled.");
        
        // 회사에 넘어갔던 토큰을 다시 펀딩으로 돌려받기
        uint256 totalCollected = crowdfunding.totalCollected;
        require(tokenContract.allowance(companyWallet, address(this)) >= totalCollected, "Insufficient allowance from company.");

        // 회사 지갑에서 펀딩 지갑으로 토큰 반환
        tokenContract.transferFrom(companyWallet, address(this), totalCollected);

        // 주문 취소 상태로 업데이트
        crowdfunding.orderCanceled = true;  // 주문 취소 상태로 설정

        emit CrowdfundingCanceled(_crowdfundingId);  // 주문 취소 이벤트 발생
    }

    

    // 4. 펀딩 참여 취소 (하객이 취소, 펀딩 지갑에서 하객 지갑으로 환불)
    function cancelContribution(uint256 _crowdfundingId) external nonReentrant {
        Crowdfunding storage crowdfunding = crowdfundings[_crowdfundingId];
        require(!crowdfunding.canceled, "The crowdfunding has been canceled.");
        uint256 contributedAmount = crowdfunding.contributions[msg.sender];
        require(contributedAmount > 0, "No refundable amount.");

        crowdfunding.contributions[msg.sender] = 0;
        crowdfunding.totalCollected -= contributedAmount;

        // 환불
        tokenContract.transfer(msg.sender, contributedAmount);

        emit Refund(msg.sender, contributedAmount);
    }

    // 5. 펀딩 취소 (부부가 호출, 부부에게 환불)
    function cancelCrowdfunding(uint256 _crowdfundingId) external nonReentrant {
        Crowdfunding storage crowdfunding = crowdfundings[_crowdfundingId];
        require(msg.sender == crowdfunding.couple, "Only the couple can cancel the crowdfunding.");
        require(!crowdfunding.canceled, "The crowdfunding has already been canceled.");
        require(crowdfunding.active, "The crowdfunding has already ended or been canceled.");

        crowdfunding.active = false;
        crowdfunding.canceled = true;

        tokenContract.transfer(crowdfunding.couple, crowdfunding.totalCollected);

        emit CrowdfundingCanceled(_crowdfundingId);
    }
}
