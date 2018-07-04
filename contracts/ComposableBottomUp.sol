pragma solidity ^0.4.24;

import "./ERC721.sol";
import "./ERC721Receiver.sol";
import "./SafeMath.sol";

interface ERC998ERC721BottomUp {
  event TransferAsChild(uint256 indexed _fromTokenId, uint256 indexed _toTokenId);
  event TransferToParent(uint256 indexed _toTokenId);
  event TransferFromParent(uint256 indexed _fromTokenId);
  /**
  * The tokenOwnerOf function gets the owner of the _tokenId which can be a user address or another ERC721 token.
  * The tokenOwner address return value can be either a user address or an ERC721 contract address.
  * If the tokenOwner address is a user address then parentTokenId will be 0 and should not be used or considered.
  * If tokenOwner address is a user address then isChild is false, otherwise isChild is true, which means that
  * tokenOwner is an ERC721 contract address and _tokenId is a child of tokenOwner and parentTokenId.
  */
  function tokenOwnerOf(uint256 _tokenId) external view returns (address tokenOwner, uint256 parentTokenId, bool isChild);
  /**
  * In a bottom-up composable authentication to transfer etc. is done by getting the rootOwner by finding the parent token
  * and then the parent token of that one until a final owner address is found.  If the msg.sender is the rootOwner or is
  * approved by the rootOwner then msg.sender is authenticated and the action can occur.
  * This enables the owner of the top-most parent of a tree of composables to call any method on child composables.
  */
  function rootOwnerOf(uint256 _tokenId) public view returns (address rootOwner);
  // Transfers _tokenId as a child to _toContract and _toTokenId
  function transferToParent(address _from, address _toContract, uint256 _toTokenId, uint256 _tokenId, uint256 _notify, bytes _data) external;
  // Transfers _tokenId from a parent ERC721 token to a user address.
  function transferFromParent(address _fromContract, uint256 _fromTokenId, address _to, uint256 _tokenId, uint256 _notify, bytes _data) external;
  // Transfers _tokenId from a parent ERC721 token to a parent ERC721 token.
  function transferAsChild(address _fromContract, uint256 _fromTokenId, address _toContract, uint256 _toTokenId, uint256 _tokenId, uint256 _notify, bytes _data) external;

  //_notify == 0, no notificatoin
  //_notify == 1, from notification -- notify fromContract that child token is being removed
  //_notify == 2, to notification -- notify toContract that child token is being received
  //_notify == 3, from and to notification -- notify fromContract and toContract

}

interface ERC998ERC721BottomUpNotifications {
  function onERC998ReceivedChild(address _operator, address _fromContract, uint256 _fromTokenId, uint256 _toTokenId, uint256 _tokenId, bytes _data) external;
  function onERC998ReceivedChild(address _operator, address _from, uint256 _toTokenId, uint256 _tokenId, bytes _data) external;
  function onERC998RemovedChild(address _operator, uint256 _fromTokenId, address _to, uint256 _tokenId, bytes _data) external;
  function onERC998RemovedChild(address _operator, uint256 _fromTokenId, address _toContract, uint256 _toTokenId, uint256 _tokenId, bytes _data) external;
}

interface ERC998ERC721BottomUpEnumerable {
  function totalChildTokens(address _parentContract, uint256 _parentTokenId) public view returns(uint256);
  function childTokenByIndex(address _parentContract, uint256 _parentTokenId, uint256 _index) public view returns(uint256);
}

contract ComposableBottomUp is ERC721, ERC998ERC721BottomUp {
  using SafeMath for uint256;

  struct TokenOwner {
    address tokenOwner;
    uint256 parentTokenId;
  }
  // tokenId => token owner
  mapping (uint256 => TokenOwner) internal tokenIdToTokenOwner;

  // root token owner address => (tokenId => approved address)
  mapping (address => mapping(uint256 => address)) internal rootTokenOwnerAndTokenIdToApprovedAddress;

  // token owner address => token count
  mapping (address => uint256) internal tokenOwnerToTokenCount;

  // token owner => (operator address => bool)
  mapping (address => mapping (address => bool)) internal tokenOwnerToOperators;

  // parent address => (parent tokenId => array of child tokenIds)
  mapping(address => mapping(uint256 => uint256[])) private parentToChildTokenIds;

  // tokenId => position in childTokens array
  mapping(uint256 => uint256) private tokenIdToChildTokenIdsIndex;

  // wrapper on minting new 721
  /*
  function mint721(address _to) public returns(uint256) {
    _mint(_to, allTokens.length + 1);
    return allTokens.length;
  }
  */
  //from zepellin ERC721Receiver.sol
  //old version
  bytes4 constant ERC721_RECEIVED = 0x150b7a02;

  function isContract(address _addr) internal view returns (bool) {
    uint256 size;
    assembly { size := extcodesize(_addr) }
    return size > 0;
  }

  function ownerOf(uint256 _tokenId) external view returns (address tokenOwner) {
    tokenOwner = tokenIdToTokenOwner[_tokenId].tokenOwner;
    require(tokenOwner != address(0));
    return tokenOwner;
  }

  function tokenOwnerOf(uint256 _tokenId) external view returns (address tokenOwner, uint256 parentTokenId, bool isChild) {
    tokenOwner = tokenIdToTokenOwner[_tokenId].tokenOwner;
    require(tokenOwner != address(0));
    parentTokenId = tokenIdToTokenOwner[_tokenId].parentTokenId;
    isChild = parentTokenId > 0;
    return (tokenOwner, parentTokenId-1, isChild);
  }

  function rootOwnerOf(uint256 _tokenId) public view returns (address rootOwner) {
    rootOwner = tokenIdToTokenOwner[_tokenId].tokenOwner;
    require(rootOwner != address(0));
    uint256 parentTokenId = tokenIdToTokenOwner[_tokenId].parentTokenId;
    bool callSuccess;
    bool isChild = parentTokenId > 0;
    bytes memory calldata;
    while(isChild) {
      //0x89885a59 == "tokenOwnerOf(uint256)"
      calldata = abi.encodeWithSelector(0x89885a59, parentTokenId);
      assembly {
        callSuccess := staticcall(gas, rootOwner, add(calldata, 0x20), mload(calldata), calldata, 0x60)
        if callSuccess {
          rootOwner := mload(calldata)
          parentTokenId := mload(add(calldata,0x20))
          isChild := mload(add(calldata,0x40))
        }
      }
      if(callSuccess == false) {
        //0x6352211e == "ownerOf(uint256)"
        calldata = abi.encodeWithSelector(0x6352211e, parentTokenId);
        assembly {
          callSuccess := staticcall(gas, rootOwner, add(calldata, 0x20), mload(calldata), calldata, 0x20)
          if callSuccess {
            rootOwner := mload(calldata)
          }
        }
        require(callSuccess, "rootOwnerOf failed");
        isChild = false;
      }
    }
    return rootOwner;
  }

  function balanceOf(address _tokenOwner)  external view returns (uint256) {
    require(_tokenOwner != address(0));
    return tokenOwnerToTokenCount[_tokenOwner];
  }


  function approve(address _approved, uint256 _tokenId) external {
    address rootOwner = rootOwnerOf(_tokenId);
    address tokenOwner = tokenIdToTokenOwner[_tokenId].tokenOwner;
    require(_approved != tokenOwner);
    require(_approved != rootOwner);
    require(tokenOwner == msg.sender || rootOwner == msg.sender
      || tokenOwnerToOperators[tokenOwner][msg.sender] || tokenOwnerToOperators[rootOwner][msg.sender]);
    rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId] = _approved;
    emit Approval(rootOwner, _approved, _tokenId);
  }

  function getApproved(uint256 _tokenId) public view returns (address)  {
    address rootOwner = rootOwnerOf(_tokenId);
    return rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId];
  }

  function setApprovalForAll(address _operator, bool _approved) external {
    require(_operator != address(0));
    tokenOwnerToOperators[msg.sender][_operator] = _approved;
    emit ApprovalForAll(msg.sender, _operator, _approved);
  }

  function isApprovedForAll(address _owner, address _operator ) external  view returns (bool)  {
    require(_owner != address(0));
    require(_operator != address(0));
    return tokenOwnerToOperators[_owner][_operator];
  }

  function removeChild(address _fromContract, uint256 _fromTokenId, uint256 _tokenId) internal {
    uint256 childTokenIndex = tokenIdToChildTokenIdsIndex[_tokenId];
    uint256 lastChildTokenIndex = parentToChildTokenIds[_fromContract][_fromTokenId].length - 1;
    uint256 lastChildTokenId = parentToChildTokenIds[_fromContract][_fromTokenId][lastChildTokenIndex];

    if(_tokenId != lastChildTokenId) {
      parentToChildTokenIds[_fromContract][_fromTokenId][childTokenIndex] = lastChildTokenId;
      tokenIdToChildTokenIdsIndex[lastChildTokenId] = childTokenIndex;
    }
    parentToChildTokenIds[_fromContract][_fromTokenId].length--;
  }

  function transferFromParent(address _fromContract, uint256 _fromTokenId, address _to, uint256 _tokenId, bool _notify, bytes _data) external {
    address tokenOwner = tokenIdToTokenOwner[_tokenId].tokenOwner;
    require(tokenOwner == _fromContract);
    require(_to != address(0));
    uint256 parentTokenId = tokenIdToTokenOwner[_tokenId].parentTokenId;
    require(parentTokenId != 0, "Token does not have a parent token.");
    require(parentTokenId-1 == _fromTokenId);
    address rootOwner = rootOwnerOf(_tokenId);
    address approvedAddress = rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId];
    require(rootOwner == msg.sender || tokenOwnerToOperators[rootOwner][msg.sender] || approvedAddress == msg.sender ||
      tokenOwner == msg.sender || tokenOwnerToOperators[tokenOwner][msg.sender]);

    // clear approval
    if(approvedAddress != address(0)) {
      delete rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId];
    }

    // remove and transfer token
    if(_fromContract != _to) {
      assert(tokenOwnerToTokenCount[_fromContract] > 0);
      tokenOwnerToTokenCount[_fromContract]--;
      tokenOwnerToTokenCount[_to]++;
    }

    tokenIdToTokenOwner[_tokenId].tokenOwner = _to;
    tokenIdToTokenOwner[_tokenId].parentTokenId = 0;

    removeChild(_fromContract, _fromTokenId,_tokenId);
    delete tokenIdToChildTokenIdsIndex[_tokenId];

    if(_notify) {
      bytes4 retval = ERC721TokenReceiver(_to).onERC721Received(msg.sender, _fromContract, _tokenId, _data);
      require(retval == ERC721_RECEIVED);
    }

    emit Transfer(_fromContract, _to, _tokenId);
    emit TransferFromParent(_fromTokenId);

  }

  function transferToParent(address _from, address _toContract, uint256 _toTokenId, uint256 _tokenId, bool _notify, bytes _data) external {
    address tokenOwner = tokenIdToTokenOwner[_tokenId].tokenOwner;
    require(tokenOwner == _from);
    require(_toContract != address(0));
    require(tokenIdToTokenOwner[_tokenId].parentTokenId == 0, "Cannot transfer from address when owned by a token.");
    address rootOwner = rootOwnerOf(_tokenId);
    address approvedAddress = rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId];
    require(rootOwner == msg.sender || tokenOwnerToOperators[rootOwner][msg.sender] || approvedAddress == msg.sender ||
      tokenOwner == msg.sender || tokenOwnerToOperators[tokenOwner][msg.sender]);

    require(ERC721(_toContract).ownerOf(_toTokenId) != address(0), "_toTokenId does not exist");

    // clear approval
    if(approvedAddress != address(0)) {
      delete rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId];
    }

    // remove and transfer token
    if(_from != _toContract) {
      assert(tokenOwnerToTokenCount[_from] > 0);
      tokenOwnerToTokenCount[_from]--;
      tokenOwnerToTokenCount[_toContract]++;
    }
    TokenOwner memory parentToken = TokenOwner(_toContract, _toTokenId.add(1));
    tokenIdToTokenOwner[_tokenId] = parentToken;
    uint256 index = parentToChildTokenIds[_toContract][_toTokenId].length;
    parentToChildTokenIds[_toContract][_toTokenId].push(_tokenId);
    tokenIdToChildTokenIdsIndex[_tokenId] = index;


    emit Transfer(_from, _toContract, _tokenId);
    emit TransferToParent(_toTokenId);
  }


  function transferAsChild(address _fromContract, uint256 _fromTokenId, address _toContract, uint256 _toTokenId, uint256 _tokenId, bool _notify, bytes _data) external {
    address tokenOwner = tokenIdToTokenOwner[_tokenId].tokenOwner;
    require(tokenOwner == _fromContract);
    require(_toContract != address(0));
    uint256 parentTokenId = tokenIdToTokenOwner[_tokenId].parentTokenId;
    require(parentTokenId > 0, "No parent token to transfer from.");
    require(parentTokenId-1 == _fromTokenId);
    address rootOwner = rootOwnerOf(_tokenId);
    require(rootOwner == msg.sender || tokenOwnerToOperators[rootOwner][msg.sender] ||
      rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId] == msg.sender ||
      tokenOwner == msg.sender || tokenOwnerToOperators[tokenOwner][msg.sender]);

    require(ERC721(_toContract).ownerOf(_toTokenId) != address(0), "_toTokenId does not exist");

    // clear approval
    if(rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId] != address(0)) {
      delete rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId];
    }

    // remove and transfer token
    if(_fromContract != _toContract) {
      assert(tokenOwnerToTokenCount[_fromContract] > 0);
      tokenOwnerToTokenCount[_fromContract]--;
      tokenOwnerToTokenCount[_toContract]++;
    }

    TokenOwner memory parentToken = TokenOwner(_toContract, _toTokenId);
    tokenIdToTokenOwner[_tokenId] = parentToken;

    removeChild(_fromContract, _fromTokenId,_tokenId);

    //add to parentToChildTokenIds
    uint256 index = parentToChildTokenIds[_toContract][_toTokenId].length;
    parentToChildTokenIds[_toContract][_toTokenId].push(_tokenId);
    tokenIdToChildTokenIdsIndex[_tokenId] = index;

    emit Transfer(_fromContract, _toContract, _tokenId);
    emit TransferAsChild(_fromTokenId, _toTokenId);

  }

  function _transferFrom(address _from, address _to, uint256 _tokenId) private {
    address tokenOwner = tokenIdToTokenOwner[_tokenId].tokenOwner;
    require(tokenOwner == _from);
    require(tokenIdToTokenOwner[_tokenId].parentTokenId == 0, "Cannot transfer from address when owned by a token.");
    require(_to != address(0));
    address rootOwner = rootOwnerOf(_tokenId);
    require(rootOwner == msg.sender || tokenOwnerToOperators[rootOwner][msg.sender] ||
      rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId] == msg.sender ||
      tokenOwner == msg.sender || tokenOwnerToOperators[tokenOwner][msg.sender]);

    // clear approval
    if(rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId] != address(0)) {
      delete rootTokenOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId];
    }

    // remove and transfer token
    if(_from != _to) {
      assert(tokenOwnerToTokenCount[_from] > 0);
      tokenOwnerToTokenCount[_from] = tokenOwnerToTokenCount[_from] - 1;
      tokenIdToTokenOwner[_tokenId].tokenOwner = _to;
      tokenOwnerToTokenCount[_to] = tokenOwnerToTokenCount[_to] + 1;
    }
    emit Transfer(_from, _to, _tokenId);
  }

  function transferFrom(address _from, address _to, uint256 _tokenId) external {
    _transferFrom(_from, _to, _tokenId);
  }

  function safeTransferFrom(address _from, address _to, uint256 _tokenId) external {
    _transferFrom(_from, _to, _tokenId);
    if(isContract(_to)) {
      bytes4 retval = ERC721TokenReceiver(_to).onERC721Received(msg.sender, _from, _tokenId, "");
      require(retval == ERC721_RECEIVED);
    }
  }

  function safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes _data) external {
    _transferFrom(_from, _to, _tokenId);
    if(isContract(_to)) {
      bytes4 retval = ERC721TokenReceiver(_to).onERC721Received(msg.sender, _from, _tokenId, _data);
      require(retval == ERC721_RECEIVED);
    }
  }

  function totalChildTokens(address _parentContract, uint256 _parentTokenId) public view returns(uint256) {
    return parentToChildTokenIds[_parentContract][_parentTokenId].length;
  }

  function childTokenByIndex(address _parentContract, uint256 _parentTokenId, uint256 _index) public view returns(uint256) {
    require(parentToChildTokenIds[_parentContract][_parentTokenId].length > _index);
    return parentToChildTokenIds[_parentContract][_parentTokenId][_index];
  }

}