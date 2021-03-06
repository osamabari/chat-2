%%%------------------------------------
%%% @Module  : connector
%%% @Author  : fengzhenlin
%%% @Email   : fengzhelin@jieyou.cn
%%% @Created : 2013/3/26
%%% @Description:  负责管理服务器与客户端的一个连接，实际就是管理一个客户端
%%%------------------------------------

-module(connector).
-compile(export_all).
-include("protocol.hrl").
-include("debug_data.hrl").

%%=========================================================================
%% 接口函数
%%=========================================================================


%%=========================================================================
%% 回调函数
%%=========================================================================



manage_one_connector(Socket,DataPid) ->
    %进入消息循环，标示为未登录
    loop(Socket,DataPid,false).


    
%接收每个客户端的消息
%每个客户端的接收循环都拥有一个客户端管理进程的ID
%以便将消息通过客户端管理进程进行广播
loop(Socket,DataPid,Is_auth) ->
    receive
        {login,succeed} ->
            %登录成功，标示为ture
            loop(Socket,DataPid,true);
        {login,false} ->
            %登录失败，直接退出
            void;
        {tcp,Socket,Bin} ->
            %获取协议命令码
            <<MsgLen:16,CmdCode:16,RestBin/binary>> = Bin,
            case Is_auth of
                true ->
                    %根据命令码进行分配处理
                    dispatcher(CmdCode,MsgLen,Bin,Socket,
                        DataPid),
                    loop(Socket,DataPid,Is_auth);

                false ->
                    if CmdCode =:= ?LOGIN_CMD_ID -> %登录
                            dispatcher(CmdCode,MsgLen,Bin,Socket,
                                DataPid);
                       CmdCode =:= ?REGISTER_CMD_ID -> %注册
                            dispatcher(CmdCode,MsgLen,Bin,Socket,
                                DataPid);
                       true -> loop(Socket,DataPid,Is_auth)

                    end,
                    loop(Socket,DataPid,Is_auth)
            end;
        {tcp_closed,Socket} ->
            %客户端下线，将客户端的Socket从列表删除
            DataPid ! {del_user_info,Socket},
            DataPid ! {del_online,Socket},
            io:format("Client(socket:~p) closed!~n",[Socket])
    end.


%根据协议命令对消息进行分配处理
dispatcher(Cmdcode,MsgLen,Bin,Socket,DataPid) ->
    %首先完成对数据包的协议分解
    case read_pt:read(Bin) of
        {ok,RevData} -> 
            GetData = list_to_tuple(RevData),
            case Cmdcode of
                ?REGISTER_CMD_ID -> register_handler(GetData,Socket,DataPid);
                ?LOGIN_CMD_ID -> login_handler(GetData,Socket,DataPid);
                ?WHOONLINE_CMD_ID -> who_online(GetData,Socket,DataPid);
                ?CHAT_SEND_CMD_ID -> chat_send(GetData,Socket,DataPid);
                ?CHAT_REV_CMD_ID -> chat_rev(GetData,Socket,DataPid);
                ?LOGIN_TIMES_CMD_ID -> login_times(GetData,Socket,DataPid);
                ?FNDONLINE_CMD_ID -> online_name(GetData,Socket,DataPid);
                ?CHAT_TIMES_CMD_ID -> chat_times(GetData,Socket,DataPid)
           end;
        {error,no_match} -> ?DEBUG("error:no_match")
    end.

%应答注册请求
register_handler(Data,Socket,_DataPid) ->
    {_MsgLen,_CmdID,Name,Psw} = Data,
    case chat_data:get_user_f_name(Name) of
        [] -> 
            NewId = chat_data:get_new_id(),
            chat_data:add_user(NewId,Name,Psw),
            SendData = {?SUCCEED,NewId},
            SendBin = write_pt:write(10101,?CMD_10101,tuple_to_list(SendData)),
            sendto(Socket,SendBin);
        _Other ->
            SendData = {?FALSE,0},
            SendBin = write_pt:write(10101,?CMD_10101,tuple_to_list(SendData)),
            sendto(Socket,SendBin)
    end.

%应答登录处理
login_handler(Data,Socket,DataPid) ->
    {_MesLen,_Command_ID,UserId,_StrPsw} = Data,
    %检测用户是否已经在线
    DataPid ! {get_socket,UserId,self()},
    receive
        {get_socket,error} -> 
            io:format("User ~p try to login!~n",[UserId]);
        {get_socket,OnlineSocket} -> 
            %对应答协议包封包
            PackData = {2,UserId,""},

            SendBin = write_pt:write(10001,?CMD_10001,tuple_to_list(PackData)),
            sendto(OnlineSocket,SendBin),
            io:format("User(Sokcet:~p) ~p has online,try to login with socket~p now!~n",[OnlineSocket,UserId,Socket]);
        _ -> io:format("Cann't not find online!~n")
    end,
    %验证登录的用户名和密码
    case auth_login(DataPid,Data,Socket) of
        {login,ok,UserId} ->

            %登录成功，修改用户相应的数据表信息
            %向ets写入用户信息
            DataPid ! {add_user_info,UserId},
            %增加一次登录次数
            DataPid ! {add_login_times,UserId},
            %修改最后一次登录时间
            DataPid ! {update_lastlogin,UserId},

            %向在线表写入数据
            DataPid ! {get_user_name,UserId,self()},
            receive
                [{_,Name,_,_,_}] -> 
                    DataPid ! {add_online,Socket,UserId,Name};
                Other -> io:format("failed to add online user info!~p,~p~n",[UserId,Other])
            end,

            %检测警报：tooMuchClient
            DataPid ! {get_online_num,self()},
            receive
                {online,Num} -> 
                    if
                        Num > 1000 ->
                            alarm_handler:set_alarm(tooMuchClient);
                        true -> void
                    end;
                _Other ->
                    alarm_handler:set_alaram()
            end,
            io:format("user ~p(socket:~p) succeed to login!~n",[UserId,Socket]),

            %登录成功，开始接收消息
            self() ! {login,succeed};
            
        {login,error} ->
            io:format("User ~p(Socket:~p) failed to login!~n",[Socket,UserId]),
            self() ! {login,false}
    end.
    

%验证登录
auth_login(DataPid,Data,Socket) ->
            {_MesLen,Command_ID,UserId,StrPsw} = Data,
            if
                Command_ID == ?LOGIN_CMD_ID ->
                    case is_auth(UserId,StrPsw,DataPid) of
                        {auth,ok} -> 
                            %向客户端返回通知，完成协议过程
                            case
                                auth_feedback(UserId,DataPid,Socket,true) of
                                true ->  {login,ok,UserId};
                                false -> {login,error}
                            end;
                        _Other -> 
                            auth_feedback(UserId,DataPid,Socket,false),
                            {login,error}
                    end;
                true -> {login,error}
            end.
        

%应答客户端的登录请求
auth_feedback(UserId,_DataPid,Socket,Is_auth) ->
    case Is_auth of
        true ->
            %对应答协议包封包
            Data = {?SUCCEED,UserId,""},
            SendBin = write_pt:write(10001,?CMD_10001,tuple_to_list(Data)),
            sendto(Socket,SendBin),
            true;

        false ->
            Data = {?FALSE,0,""},
            SendBin = write_pt:write(10001,?CMD_10001,tuple_to_list(Data)),
            sendto(Socket,SendBin),
            false
    end.

            

%验证用户名和密码
is_auth(UserId,Psw,DataPid) ->
    DataPid ! {get_user_psw,UserId,self()},
    receive
        [{_,Psw}] -> 
            {auth,ok};
        %用户名或者密码错误
        _Other -> {auth,error}
    end.


%应答查看在线人数请求
who_online(BinData,Socket,DataPid) ->
    {_Message_Len,Command_Id} = BinData,
    DataPid ! {get_online_num,self()},
    receive
        {online,N} -> 
            ResponseData = {0,N},
            ResponseBin = write_pt:write(10002,?CMD_10002,tuple_to_list(ResponseData)),
            sendto(Socket,ResponseBin);
        _Other -> void
    end.

%应答聊天请求
chat_send(BinData,Socket,DataPid) ->

    {_Message_Len,_Command_ID,_Send_User_Id,_Send_User_Name,
        Rev_User_Name,_Send_Data_Type,Send_Data} = BinData,

    %首先查找发送者信息，然后在消息中添加发送者信息
    DataPid ! {get_online_name,Socket,self()},
    receive
        [{_,UserId,UserName}] ->
             %对应答内容进行封包处理
             Data = {UserId,UserName,?SUCCEED,Send_Data},
             SendBin = write_pt:write(10005,?CMD_10005,tuple_to_list(Data)),
             case Rev_User_Name of
                 "" -> %群发
                    DataPid ! {all_online_socket,self()},
                    receive
                        {all_online,ClientList} ->
                        %广播信息
                        send_data_to_list(ClientList,SendBin);
                        _Other -> io:format("error to get online info~n")
                    end;
                 _ -> %私聊
                     DataPid ! {get_socket_f_name,Rev_User_Name,self()},
                     receive
                         {get_socket_f_name,error} -> 
                             BackStr = "error:user is offline,failed to send msg!",
                             io:format("~p,~p~n",[BackStr,Send_Data]),
                             BackData = {UserId,UserName,?SUCCEED,BackStr},
                             BackBin = write_pt:write(10005,?CMD_10005,tuple_to_list(BackData)),
                             sendto(Socket,BackBin),
                             io:format("user ~p not online~n",[Rev_User_Name]);
                         {get_socket_f_name,USocket} -> sendto(USocket,SendBin)
                     end
             end,
             %向数据库添加聊天次数
             DataPid ! {add_chat_times,UserId};
       _Other -> 
             void
    end.



chat_rev(_BinData,_Socket,_DataPid) ->
    void.

%查看登录次数
login_times(RevData,Socket,DataPid) ->
    {   _Message_Len,
        _Command_Id,
        User_Id } = RevData,
    DataPid ! {get_login_times,User_Id,self()},
    receive
        {login_times,LoginTimes} -> 
            Data = {0,LoginTimes},
            SendBin = write_pt:write(10006,?CMD_10006,tuple_to_list(Data)),
            sendto(Socket,SendBin);
        _Other -> io:format("connector login_times error!~n")
    end.

%查看聊天次数
chat_times(RevData,Socket,DataPid) ->
     {  _Message_Len,
        _Command_Id,
        User_Id } = RevData,
    DataPid ! {get_chat_times,User_Id,self()},
    receive
        {chat_times,ChatTimes} -> 
            Data = {0,ChatTimes},
            SendBin = write_pt:write(10007,?CMD_10007,tuple_to_list(Data)),
            sendto(Socket,SendBin);
        _Other -> io:format("connector chat_times error!~n")
    end.

%获取所有在线用户名称
online_name(_RevData,Socket,DataPid) ->
    DataPid ! {get_all_online_name,self()},
    receive
        {L} -> 
            io:format("Get online name:~p~n",[L]), 
            ListLen = list_length(L),
            Data = L,
            SendBin = write_pt:write(10003,[{array,ListLen,[string]}],Data),
            sendto(Socket,SendBin);

        _Other -> ?DEBUG("no online!")
    end.

list_length([]) ->
     0; 

 list_length([First | Rest]) ->
     1 + list_length(Rest).


sendto(Socket,Bin) ->
    gen_tcp:send(Socket,Bin).

%对客户端列表进行数据广播
send_data_to_list(SocketList,Bin) ->
    lists:foreach(fun(Socket) ->
                gen_tcp:send(Socket,Bin)
                  end,
                  SocketList).
