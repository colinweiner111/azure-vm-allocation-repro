# Zonal Windows VM Deployment with Ultra Disk Compatibility

This Bicep deployment tests zonal Windows VM allocation with Ultra Disk
compatibility enabled, using an existing resource group, VNet, and subnet. The
VM SKU and Azure region are required deployment parameters.

> **Zonal and Ultra Disk configuration:** This repository deploys the VM into
> a required logical availability zone (`1`, `2`, or `3`) and sets
> `additionalCapabilities.ultraSSDEnabled` to `true`. It does not support
> regional/non-zonal placement. No Ultra data disk is attached.

The deployment uses:

- Region: Required deployment parameter; must match the existing VNet region
  (`westus2` for the intended repro)
- VM size: Required deployment parameter (`Standard_E48bds_v5` for the intended
  repro)
- Image SKU: Optional deployment parameter; defaults to Windows Server 2025
  Datacenter x64 Gen2 (`2025-datacenter-g2`)
- Security: Trusted Launch with Secure Boot and vTPM enabled
- OS disk: Managed Premium SSD (`Premium_LRS`)
- Ultra Disk compatibility: Required and enabled, with no Ultra data disk attached
- Network: Existing VNet and subnet with a dynamic private IP and no public IP
- Placement: Zonal only; logical availability zone 1, 2, or 3 is required
- Redundancy: No availability set or VM scale set

## Prerequisites

- **PowerShell 7.2+** and **Azure CLI with Bicep support**.
- **Contributor on the existing resource group** or equivalent permissions.
- An **existing VM resource group, VNet, and subnet**. The VNet can be in a
  different resource group. The deployment never creates, updates, or deletes
  the VNet or subnet.
- Sufficient regional and VM-family vCPU quota.
- The selected VM size must be available to the subscription in the VNet's
  region. For a zonal test, it must support the selected logical zone.
- Ultra Disk compatibility must be supported for the selected size and
  placement.

> **Cost and placement:** `ultraSSDEnabled: true` can incur an Ultra Disk
> reservation charge even when no Ultra data disk is attached, and it limits
> allocation to Ultra-capable hardware. This is intentional because the
> template reproduces that configuration. Include this setting in the Azure
> Support case, and delete test resources promptly.

## Deploy

Clone the repository:

```powershell
git clone https://github.com/colinweiner111/azure-vm-allocation-repro.git
cd azure-vm-allocation-repro
```

### Deploy to an availability zone

```powershell
.\deploy-bicep.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroupName "<vm-resource-group>" `
  -Location "westus2" `
  -VnetResourceGroup "<vnet-resource-group>" `
  -VnetName "<existing-vnet>" `
  -SubnetName "<existing-subnet>" `
  -VmName "<unique-zonal-vm-name>" `
  -VmSize "Standard_E48bds_v5" `
  -Zone 1
```

Example with sample resource names:

```powershell
.\deploy-bicep.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroupName "rg-vm-allocation-test" `
  -Location "westus2" `
  -VnetResourceGroup "rg-shared-network" `
  -VnetName "vnet-westus2" `
  -SubnetName "snet-vm" `
  -VmName "e48bds-z1-01" `
  -VmSize "Standard_E48bds_v5" `
  -Zone 1
```

Use a unique `-VmName` for every allocation attempt so Azure creates a new VM
instead of updating an earlier deployment.

To use a different Windows Server image SKU, add:

```powershell
-ImageSku "<windows-server-image-sku>"
```

The image publisher remains `MicrosoftWindowsServer`, the offer remains
`WindowsServer`, and the version remains `latest`.

Zone numbers are logical per subscription. Include the subscription ID,
logical zone, deployment name, and printed correlation ID in any Azure Support
case.

### Deployment parameters

| PowerShell&nbsp;parameter | Required | Default | Description |
|---|---|---|---|
| `-SubscriptionId` | Yes | None | Azure subscription ID used for the deployment |
| `-ResourceGroupName` | Yes | None | Existing resource group where the VM, NIC, and OS disk are deployed |
| `-Location` | Yes | None | Azure region; must match the existing VNet region |
| `-VnetResourceGroup` | Yes | None | Resource group containing the existing VNet and subnet |
| `-VnetName` | Yes | None | Existing VNet; the deployment never creates or modifies it |
| `-SubnetName` | Yes | None | Existing subnet used by the VM NIC |
| `-VmName` | Yes | None | Unique VM name for this allocation attempt |
| `-VmSize` | Yes | None | Exact VM SKU to test, such as `Standard_E48bds_v5` |
| `-ImageSku` | No | `2025-datacenter-g2` | Windows Server image SKU |
| `-Zone` | Yes | None | Logical availability zone `1`, `2`, or `3` |
| `-AdminUsername` | No | Prompted | Local Windows administrator username |
| `-AdminPassword` | No | Securely prompted | Local Windows administrator password as a PowerShell `SecureString` |

`-Location` must match the region of the existing VNet. The examples use
`westus2` for the intended allocation reproduction.

The script will:

1. Prompt for the local VM administrator username and password
2. Sign in to Azure if needed and select the subscription
3. Verify that the existing resource group is available
4. Deploy with the supplied VM resource group, location, VNet resource group,
   VNet, subnet, VM name, size, and logical availability zone
5. Print the timestamped ARM deployment name and correlation ID

The password is stored in a user-scoped temporary parameter file only for the
duration of the deployment and is removed in a `finally` block. It is not
placed on the Azure CLI command line. No Bicep file edits are required.

## Optional pre-checks

Check SKU restrictions and zone-specific Ultra Disk capability:

```powershell
az vm list-skus `
  --location westus2 `
  --size Standard_E48bds_v5 `
  --zone `
  --all `
  --query "[].{name:name,zones:locationInfo[0].zones,zoneDetails:locationInfo[0].zoneDetails,restrictions:restrictions}" `
  --output jsonc
```

Check regional and VM-family quota:

```powershell
az vm list-usage `
  --location westus2 `
  --query "[?contains(name.localizedValue, 'Total Regional') || contains(name.localizedValue, 'EBDSv5')]" `
  --output table
```

## Verify

```powershell
az vm get-instance-view `
  --resource-group "<existing-resource-group>" `
  --name "<vm-name>" `
  --output jsonc
```

## Cleanup

Deleting a successfully created VM also deletes its attached NIC and OS disk:

```powershell
az vm delete `
  --resource-group "<existing-resource-group>" `
  --name "<vm-name>" `
  --yes
```

If VM creation failed before the VM resource existed, check for orphaned test
resources:

```powershell
az network nic show `
  --resource-group "<existing-resource-group>" `
  --name "<vm-name>-nic"

az disk show `
  --resource-group "<existing-resource-group>" `
  --name "<vm-name>-osdisk"
```

After confirming they belong to this test, remove them:

```powershell
az network nic delete `
  --resource-group "<existing-resource-group>" `
  --name "<vm-name>-nic"

az disk delete `
  --resource-group "<existing-resource-group>" `
  --name "<vm-name>-osdisk" `
  --yes
```

The existing resource group, VNet, and subnet are never modified or deleted by
this template.
