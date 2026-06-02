#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the installer's pure helpers. The installer script is
    dot-sourced with TODO_INSTALL_NORUN=1 so its functions are defined without
    running the interactive flow.
#>

BeforeAll {
    $env:TODO_INSTALL_NORUN = '1'
    . (Join-Path $PSScriptRoot '..' 'install.ps1')

    function New-TestDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("insttest_" + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($d)
        return $d
    }
}

AfterAll {
    Remove-Item Env:\TODO_INSTALL_NORUN -ErrorAction SilentlyContinue
}

Describe 'New-TodoCliConfigContent' {
    It 'always emits TODO_DIR and the toggles (off by default)' {
        $c = New-TodoCliConfigContent -TodoDir '/home/me/.todo'
        $c | Should -Match 'export TODO_DIR="/home/me/.todo"'
        $c | Should -Match 'export TODOTXT_GIT=0'
        $c | Should -Match 'export TODOTXT_IN_PROGRESS=0'
        $c | Should -Match 'export TODOTXT_DATE_TAGS=0'
        $c | Should -Not -Match 'TODOTXT_GIT_REMOTE'
    }
    It 'emits enabled toggles and a remote' {
        $c = New-TodoCliConfigContent -TodoDir '/t' -Git $true -GitRemote 'git@x:me/t.git' -InProgress $true -DateTags $true
        $c | Should -Match 'export TODOTXT_GIT=1'
        $c | Should -Match 'export TODOTXT_GIT_REMOTE="git@x:me/t.git"'
        $c | Should -Match 'export TODOTXT_IN_PROGRESS=1'
        $c | Should -Match 'export TODOTXT_DATE_TAGS=1'
    }
    It 'produces content the module config parser accepts' {
        Import-Module (Join-Path $PSScriptRoot '..' 'src' 'TodoTxt.psd1') -Force
        $dir = New-TestDir
        try {
            $cfgFile = Join-Path $dir 'config'
            Set-Content -LiteralPath $cfgFile -Value (New-TodoCliConfigContent -TodoDir $dir -Git $true -InProgress $true) -NoNewline
            $cfg = New-TodoConfig -ConfigFile $cfgFile
            $cfg.Git | Should -BeTrue
            $cfg.InProgress | Should -BeTrue
            $cfg.TodoDir | Should -Be $dir
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Add-TodoProfileFunction' {
    It 'creates the profile and inserts one todo function block' {
        $dir = New-TestDir
        try {
            $profilePath = Join-Path $dir 'Microsoft.PowerShell_profile.ps1'
            Add-TodoProfileFunction -ProfilePath $profilePath -WrapperPath '/opt/todo/todo.ps1'
            $content = Get-Content -Raw $profilePath
            $content | Should -Match 'function todo'
            $content | Should -Match '/opt/todo/todo.ps1'
            ([regex]::Matches($content, '# >>> todo-cli >>>')).Count | Should -Be 1
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'is idempotent: running twice leaves exactly one block' {
        $dir = New-TestDir
        try {
            $profilePath = Join-Path $dir 'profile.ps1'
            'Write-Host "existing profile"' | Set-Content $profilePath
            Add-TodoProfileFunction -ProfilePath $profilePath -WrapperPath '/a/todo.ps1'
            Add-TodoProfileFunction -ProfilePath $profilePath -WrapperPath '/b/todo.ps1'
            $content = Get-Content -Raw $profilePath
            ([regex]::Matches($content, '# >>> todo-cli >>>')).Count | Should -Be 1
            # the second run wins and the original content is preserved
            $content | Should -Match '/b/todo.ps1'
            $content | Should -Not -Match '/a/todo.ps1'
            $content | Should -Match 'existing profile'
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
