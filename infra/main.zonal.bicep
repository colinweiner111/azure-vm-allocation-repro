targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = 'westus2'

@description('Name of the virtual machine.')
@maxLength(15)
param vmName string

@description('Azure VM size to test.')
param vmSize string = 'Standard_E48bds_v5'

@description('Windows Server image SKU.')
param imageSku string = '2025-datacenter-g2'

@description('Local administrator username for the virtual machine.')
param adminUsername string

@secure()
@description('Local administrator password for the virtual machine.')
param adminPassword string

@description('Name of the virtual network.')
param vnetName string

@description('Name of the resource group containing the existing virtual network.')
param vnetResourceGroup string

@description('Name of the subnet.')
param subnetName string

@allowed([
  '1'
  '2'
  '3'
])
@description('Logical availability zone for the VM.')
param zone string = '1'

var nicName = '${vmName}-nic'
var subnetResourceId = resourceId(vnetResourceGroup, 'Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)

resource nic 'Microsoft.Network/networkInterfaces@2024-07-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetResourceId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  zones: [
    zone
  ]
  properties: {
    additionalCapabilities: {
      ultraSSDEnabled: true
    }
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: imageSku
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-osdisk'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
            deleteOption: 'Delete'
          }
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}

output vmResourceId string = vm.id
output deployedVmName string = vm.name
output deployedVmSize string = vmSize
output azureRegion string = location
