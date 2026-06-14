# otter 
使用tmux快速启动claude、yazi、nvim,lazygit等终端工具脚本

## 任务
- 启动脚本，**将完成的脚本写入 @zoo-scripts/**
    - [ ] 在当前目录下快速启动tmux，支持用户自定义session名称，使用-s表示seesion name,若用户未输入session名称，则是用目录名称作为session name
    - [ ] 增加参数-c，该参数为必须输入的参数，输入需要启动的cli工具，若输入claude则启动claude
    - [ ] 在启动的tmux中打开三个window，名称分别为claude、nvim、lazygit
    - [ ] 第一个窗口，根据用户输入的-c参数，即CLI_TOOL,启动的窗口名称=$CLI_TOOL,要求该窗口启动三个pane
        - [ ] 第1个pane左半部分，启动对应的cli工具
        - [ ] 第2个pane右上部分，启动yazi
        - [ ] 第3个pane右下部分，不做任何操作，只是在当前目录下
    - [ ] 第二个窗口可选启动，若用户安装了nvim，则创建该窗口并执行`nvim .`
    - [ ] 第三个窗口可选启动，若用户是git目录，且安装了lazygit，则创建该窗口并启动lazygit
- 安装脚本cli-zoo-install.sh
    - [ ] 增加安装选项otter，将otter软连接至/usr/local/bin/目录下，即/usr/local/bin/otter
    - [ ] 若/usr/local/bin/目录下已经存在otter,则先删除在重新软连
- 卸载脚本cli-zoo-uninstall.sh
    - [ ] 增加卸载选项otter，将otter软连接从/usr/local/bin/目录下删除，若不存在otter则直接成功
- [ ] 功能完成后需要编写测试用例@.test_task/otter-test-task.md
- [ ] 测试用例编写完成后根据@.test_task/otter-test.md测试用例，编写测试脚本@.test_scripts/otter-test.sh
- [ ] 测试脚本编写完成后运行测试脚本@.test_scripts/otter-test.sh，将测试结果写入@.test_res/otter-test-res.md
- [ ] 根据-c参数检测对应cli工具是否存在，若cli工具不存在则提示用户当前未安装该软件并结束启动
- [ ] 若用户先执行`otter -c claude -s A`,再执行`otter -c opencode -s A`,则直接在session A中创建opencode窗口即可
- [ ] 若用户先执行`otter -c claude -s A`,再执行`otter -c claude -s A`,则直接attach至session A即可，因为session A已经创建了claude窗口
- [ ] otter增加关闭session功能，参数为-ks，参数为对应的session名称，ks为kill-session缩写，若不存在该session则提示用户不存在并执行结束
